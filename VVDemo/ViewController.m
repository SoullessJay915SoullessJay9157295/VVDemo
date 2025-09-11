//
//  ViewController.m
//  Created on 2025/9/9
//  Description: 动态小球循环动画 + ReplayKit H264 推流
//

#import "ViewController.h"
#import <VideoToolbox/VideoToolbox.h>
#import <MQCocoaAsyncSocket/GCDAsyncSocket.h>

@interface ViewController ()<GCDAsyncSocketDelegate>
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSInteger seconds;
@property (nonatomic, strong) UIButton *connectButton;

@property (nonatomic, strong) dispatch_queue_t socketQueue;
@property (nonatomic, strong) dispatch_queue_t encoderQueue;
@property (nonatomic, strong) GCDAsyncSocket *socket;

@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) NSInteger frameCount;

@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) int width, height;
@property (nonatomic, strong) NSData *spsData, *ppsData;
@property (nonatomic, assign) int nalUnitLength;

@property (nonatomic, strong) UIView *animationView;
@property (nonatomic, strong) NSMutableArray<UIView *> *movingBalls;
@property (nonatomic, strong) NSMutableArray<NSValue *> *ballVelocities;

@property (nonatomic, assign) int fps; // 可配置帧率
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.seconds = 0;
    self.fps = 30; // 默认帧率
    self.socketQueue = dispatch_queue_create("com.demo.socketQueue", DISPATCH_QUEUE_CONCURRENT);
    self.encoderQueue = dispatch_queue_create("com.demo.encoderQueue", DISPATCH_QUEUE_SERIAL);

    [self setupUI];
    [self startTimer];
}

- (void)dealloc {
    [self.timer invalidate];
    self.timer = nil;
    [self.socket disconnect];
    self.socket.delegate = nil;
    self.socket = nil;
}

#pragma mark - UI
- (void)setupUI {
    self.timeLabel = [self createLabelWithFrame:CGRectMake(100, 200, 200, 50)];
    [self.view addSubview:self.timeLabel];

    self.connectButton = [self createButtonWithFrame:CGRectMake(100, 300, 150, 50)
                                               title:@"开始发送"
                                              action:@selector(startSocketAndSend)];
    [self.view addSubview:self.connectButton];

    self.animationView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.animationView.backgroundColor = [UIColor whiteColor];
    [self.view addSubview:self.animationView];
    [self.view sendSubviewToBack:self.animationView];

    self.movingBalls = [NSMutableArray array];
    self.ballVelocities = [NSMutableArray array];
    int ballCount = 50;
    for (int i = 0; i < ballCount; i++) {
        CGFloat radius = 10 + arc4random_uniform(10);
        UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(arc4random_uniform((int)self.view.bounds.size.width),
                                                                arc4random_uniform((int)self.view.bounds.size.height),
                                                                radius*2, radius*2)];
        ball.backgroundColor = [UIColor colorWithHue:(arc4random_uniform(100)/100.0)
                                         saturation:0.8
                                         brightness:1
                                              alpha:1];
        ball.layer.cornerRadius = radius;
        [self.animationView addSubview:ball];
        [self.movingBalls addObject:ball];

        CGFloat dx = (arc4random_uniform(11) - 5);
        CGFloat dy = (arc4random_uniform(11) - 5);
        [self.ballVelocities addObject:[NSValue valueWithCGPoint:CGPointMake(dx, dy)]];
    }
}

- (UILabel *)createLabelWithFrame:(CGRect)frame {
    UILabel *label = [[UILabel alloc] initWithFrame:frame];
    label.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    label.textColor = [UIColor blackColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.text = @"0";
    return label;
}

- (UIButton *)createButtonWithFrame:(CGRect)frame title:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Timer
- (void)startTimer {
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(updateTime)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)updateTime {
    self.seconds++;
    self.timeLabel.text = [NSString stringWithFormat:@"%ld", (long)self.seconds];
}

#pragma mark - Socket
- (void)startSocketAndSend {
    self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:self.socketQueue];
    NSError *error = nil;
    NSString *ip = @"192.168.0.112";
    uint16_t port = 9000;

    if (![self.socket connectToHost:ip onPort:port error:&error]) {
        NSLog(@"连接失败: %@", error);
    } else {
        NSLog(@"正在连接 %@", ip);
    }
}

- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    NSLog(@"连接成功: %@:%d", host, port);

    CGSize size = UIScreen.mainScreen.bounds.size;
    int w = (int)round(size.width), h = (int)round(size.height);
    if (w % 2) w--; if (h % 2) h--;
    
    dispatch_async(self.encoderQueue, ^{
        [self startCompressionSessionWithWidth:w height:h fps:self.fps bitrate:1000*1000];
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startDisplayLink];
    });
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    NSLog(@"socket disconnected: %@", err);
    dispatch_async(dispatch_get_main_queue(), ^{ [self stopDisplayLink]; });
    dispatch_async(self.encoderQueue, ^{ [self stopCompressionSession]; });
}

#pragma mark - DisplayLink
- (void)startDisplayLink {
    if (self.displayLink) return;
    self.frameCount = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
    self.displayLink.preferredFramesPerSecond = self.fps;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)displayLinkFired:(CADisplayLink *)link {
    self.frameCount++;
    [self updateAnimation];

    dispatch_async(self.encoderQueue, ^{
        [self encodeAnimationViewLayer];
    });
}

#pragma mark - 动画更新
- (void)updateAnimation {
    for (int i = 0; i < self.movingBalls.count; i++) {
        UIView *ball = self.movingBalls[i];
        CGPoint velocity = [self.ballVelocities[i] CGPointValue];

        CGPoint center = ball.center;
        center.x += velocity.x;
        center.y += velocity.y;

        if (center.x < 0 || center.x > self.animationView.bounds.size.width) {
            velocity.x = -velocity.x;
            center.x += velocity.x;
        }
        if (center.y < 0 || center.y > self.animationView.bounds.size.height) {
            velocity.y = -velocity.y;
            center.y += velocity.y;
        }

        ball.center = center;
        self.ballVelocities[i] = [NSValue valueWithCGPoint:velocity];
    }
}

#pragma mark - VideoToolbox
static uint32_t parseNalLength(const uint8_t *buf, int nalHeaderLen) {
    uint32_t len = 0;
    for (int i = 0; i < nalHeaderLen; i++) {
        len = (len << 8) | buf[i];
    }
    return len;
}

static void compressionOutputCallback(void *outputCallbackRefCon,
                                      void *sourceFrameRefCon,
                                      OSStatus status,
                                      VTEncodeInfoFlags infoFlags,
                                      CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !CMSampleBufferDataIsReady(sampleBuffer)) return;
    ViewController *vc = (__bridge ViewController *)outputCallbackRefCon;

    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (fmt && !vc.spsData) {
        const uint8_t *sps, *pps; size_t spsSize, ppsSize;
        int nalLen;
        if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsSize, NULL, &nalLen) == noErr &&
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsSize, NULL, &nalLen) == noErr) {
            vc.spsData = [NSData dataWithBytes:sps length:spsSize];
            vc.ppsData = [NSData dataWithBytes:pps length:ppsSize];
            vc.nalUnitLength = nalLen;
        }
    }

    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) return;

    size_t totalLen; char *dataPtr; size_t offsetLen;
    if (CMBlockBufferGetDataPointer(dataBuffer, 0, &offsetLen, &totalLen, &dataPtr) != noErr) return;
    const uint8_t *buf = (const uint8_t *)dataPtr;
    int nalLenSize = vc.nalUnitLength > 0 ? vc.nalUnitLength : 4;

    BOOL hasIDR = NO; size_t off = 0;
    while (off + nalLenSize <= totalLen) {
        uint32_t nalLen = (nalLenSize == 4) ? CFSwapInt32BigToHost(*(uint32_t *)(buf+off)) : parseNalLength(buf+off, nalLenSize);
        off += nalLenSize; if (!nalLen || off + nalLen > totalLen) break;
        if ((buf[off] & 0x1F) == 5) { hasIDR = YES; break; }
        off += nalLen;
    }

    NSMutableData *out = [NSMutableData data];
    const uint8_t startCode[4] = {0,0,0,1};
    if (hasIDR && vc.spsData && vc.ppsData) {
        [out appendBytes:startCode length:4]; [out appendData:vc.spsData];
        [out appendBytes:startCode length:4]; [out appendData:vc.ppsData];
    }

    size_t offset = 0;
    while (offset + nalLenSize <= totalLen) {
        uint32_t nalLen = (nalLenSize == 4) ? CFSwapInt32BigToHost(*(uint32_t *)(buf+offset)) : parseNalLength(buf+offset, nalLenSize);
        offset += nalLenSize;
        if (!nalLen || offset + nalLen > totalLen) break;
        [out appendBytes:startCode length:4];
        [out appendBytes:buf+offset length:nalLen];
        offset += nalLen;
    }

    if (out.length) {
        dispatch_async(vc.socketQueue, ^{
            if (vc.socket.isConnected) [vc.socket writeData:out withTimeout:-1 tag:0];
        });
    }
}

- (void)startCompressionSessionWithWidth:(int)w height:(int)h fps:(int)fps bitrate:(int)bitrate {
    [self stopCompressionSession];
    self.width = w; self.height = h; self.frameCount = 0;

    OSStatus s = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264,
                                            NULL, NULL, NULL,
                                            compressionOutputCallback,
                                            (__bridge void *)self, &_compressionSession);
    if (s != noErr) return;

    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    CFNumberRef br = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_AverageBitRate, br);
    CFRelease(br);

    int maxBR = bitrate * 2;
    CFNumberRef maxRef = CFNumberCreate(NULL, kCFNumberIntType, &maxBR);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_DataRateLimits, maxRef);
    CFRelease(maxRef);

    int gop = fps;
    CFNumberRef gopRef = CFNumberCreate(NULL, kCFNumberIntType, &gop);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, gopRef);
    CFRelease(gopRef);

    CFNumberRef fpsRef = CFNumberCreate(NULL, kCFNumberIntType, &fps);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Baseline_AutoLevel);
    VTCompressionSessionPrepareToEncodeFrames(self.compressionSession);
}

- (void)stopCompressionSession {
    if (!self.compressionSession) return;
    VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
    VTCompressionSessionInvalidate(self.compressionSession);
    CFRelease(self.compressionSession);
    self.compressionSession = NULL;
    self.spsData = self.ppsData = nil;
}

#pragma mark - Encode AnimationView
- (void)encodeAnimationViewLayer {
    if (!self.compressionSession) return;

    int w = self.width, h = self.height;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    CVPixelBufferRef buf = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &buf) != kCVReturnSuccess) return;

    CVPixelBufferLockBaseAddress(buf, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buf),
                                             w, h, 8,
                                             CVPixelBufferGetBytesPerRow(buf),
                                             CGColorSpaceCreateDeviceRGB(),
                                             kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    
    [self.view.layer renderInContext:ctx];
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(buf, 0);

    CMTime pts = CMTimeMake(self.frameCount, self.fps);
    CMTime dur = CMTimeMake(1, self.fps);
    VTEncodeInfoFlags flags;
    VTCompressionSessionEncodeFrame(self.compressionSession, buf, pts, dur, NULL, NULL, &flags);
    CVPixelBufferRelease(buf);
}

@end
