//
//  ViewController.m
//  Created on 2025/9/9
//  Description <#文件描述#>
//  PD <#产品文档地址#>
//  Design <#设计文档地址#>
//  Copyright © 2025 LMKJ. All rights reserved.
//  @author 刘小彬(liuxiaomike@gmail.com)
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
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, strong) NSData *spsData;
@property (nonatomic, strong) NSData *ppsData;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.seconds = 0;
    self.socketQueue = dispatch_queue_create("com.demo.socketQueue", DISPATCH_QUEUE_CONCURRENT);
    self.encoderQueue = dispatch_queue_create("com.demo.encoderQueue", DISPATCH_QUEUE_SERIAL);
    
    // 创建一个Label来显示时间
    self.timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(100, 200, 200, 50)];
    self.timeLabel.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    self.timeLabel.textColor = [UIColor blackColor];
    self.timeLabel.textAlignment = NSTextAlignmentCenter;
    self.timeLabel.text = @"0";
    [self.view addSubview:self.timeLabel];
    
    // 按钮
    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.connectButton.frame = CGRectMake(100, 300, 150, 50);
    [self.connectButton setTitle:@"开始发送" forState:UIControlStateNormal];
    [self.connectButton addTarget:self action:@selector(startSocketAndSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.connectButton];
    
    
    // 创建定时器，每秒执行一次
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                  target:self
                                                selector:@selector(updateTime)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)dealloc {
    [self.timer invalidate];
    self.timer = nil;
    if (self.socket) {
        [self.socket disconnect];
        self.socket.delegate = nil;
        self.socket = nil;
    }
}

#pragma mark - UI Timer
- (void)updateTime {
    self.seconds += 1;
    self.timeLabel.text = [NSString stringWithFormat:@"%ld", (long)self.seconds];
}


// 点击按钮后执行
- (void)startSocketAndSend {
    
    self.socket = [[GCDAsyncSocket alloc] initWithDelegate:self delegateQueue:self.socketQueue];
    
    NSError *error = nil;
    NSString *ip = @"192.168.0.112"; // 目标IP
    uint16_t port = 9000;           // 目标端口
    
    if (![self.socket connectToHost:ip onPort:port error:&error]) {
        NSLog(@"连接失败: %@", error);
    } else {
        NSLog(@"正在连接 %@", ip);
    }
}

#pragma mark - GCDAsyncSocketDelegate
- (void)socket:(GCDAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port {
    NSLog(@"连接成功: %@:%d", host, port);
    
    // 启动编码会话（根据当前屏幕尺寸）
    CGSize size = UIScreen.mainScreen.bounds.size;
    // 取偶数宽高（VideoToolbox 对奇数可能异常）
    int w = (int)round(size.width);
    int h = (int)round(size.height);
    if (w % 2 != 0) w--;
    if (h % 2 != 0) h--;
    
    dispatch_async(self.encoderQueue, ^{
        [self startCompressionSessionWithWidth:w height:h fps:30 bitrate:1000*1000]; // 1Mbps
    });
    
    // 启动 displayLink 在主线程
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startDisplayLink];
    });
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)err {
    
    NSLog(@"socket disconnected: %@", err);
    // 停止采集与编码
    dispatch_async(dispatch_get_main_queue(), ^{
        [self stopDisplayLink];
    });
    dispatch_async(self.encoderQueue, ^{
        [self stopCompressionSession];
    });
}

#pragma mark - DisplayLink
- (void)startDisplayLink {
    if (self.displayLink) return;
    self.frameCount = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
    self.displayLink.preferredFramesPerSecond = 30;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopDisplayLink {
    if (!self.displayLink) return;
    [self.displayLink invalidate];
    self.displayLink = nil;
}

- (void)displayLinkFired:(CADisplayLink *)link {
    // 每帧截屏在主线程
    self.frameCount++;
    [self captureScreenWithCompletion:^(UIImage *image) {
        
        if (image) {
            // 将图片交给 encoderQueue 处理（转换为 CVPixelBuffer 并编码）
            dispatch_async(self.encoderQueue, ^{
                [self encodeUIImage:image atFrame:self.frameCount];
            });
        }
    }];
    
}


-(void)captureScreenWithCompletion:(void(^)(UIImage *image))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [self currentWindowOnMainThread];
        if (!window) {
            if (completion) completion(nil);
            return;
        }
        
        UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, 1.0);
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        if (completion) {
            completion(image);
        }
    });
}

// 这个方法保证只在主线程访问 UI
- (UIWindow *)currentWindowOnMainThread {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in scene.windows) {
                if (w.isKeyWindow) {
                    return w;
                }
            }
        }
    }
    return nil;
}


#pragma mark - VideoToolbox (H264) Setup / Encode / Teardown

// 回调函数声明 (C 函数)
static void compressionOutputCallback(void *outputCallbackRefCon,
                                      void *sourceFrameRefCon,
                                      OSStatus status,
                                      VTEncodeInfoFlags infoFlags,
                                      CMSampleBufferRef sampleBuffer) {
    if (status != noErr) {
        NSLog(@"VTCompression status error: %d", (int)status);
        return;
    }
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        NSLog(@"sampleBuffer data not ready");
        return;
    }

    ViewController *vc = (__bridge ViewController *)outputCallbackRefCon;

    // ---- 从 format description 尝试抓取 SPS/PPS 并拿到 nalUnitHeaderLength ----
    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (formatDesc) {
        const uint8_t *spsPtr = NULL, *ppsPtr = NULL;
        size_t spsSize = 0, ppsSize = 0;
        size_t spsCount = 0, ppsCount = 0;
        int nalHeaderLen = 0;

        OSStatus err = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc,
                                                                         0,
                                                                         &spsPtr,
                                                                         &spsSize,
                                                                         &spsCount,
                                                                         &nalHeaderLen);
        if (err == noErr) {
            err = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDesc,
                                                                     1,
                                                                     &ppsPtr,
                                                                     &ppsSize,
                                                                     &ppsCount,
                                                                     &nalHeaderLen);
            if (err == noErr && spsSize > 0 && ppsSize > 0) {
                vc.spsData = [NSData dataWithBytes:spsPtr length:spsSize];
                vc.ppsData = [NSData dataWithBytes:ppsPtr length:ppsSize];
                vc.nalUnitLength = nalHeaderLen; // 保存 length 字段大小（通常是 4）
                NSLog(@"Got SPS(%zu) PPS(%zu) nalLen=%d", spsSize, ppsSize, nalHeaderLen);

                if (vc.spsData.length > 0) {
                    const uint8_t *b = vc.spsData.bytes;
                    NSLog(@"SPS first byte: 0x%02x type=%d", b[0], b[0] & 0x1F);
                }
                if (vc.ppsData.length > 0) {
                    const uint8_t *b = vc.ppsData.bytes;
                    NSLog(@"PPS first byte: 0x%02x type=%d", b[0], b[0] & 0x1F);
                }
            }
        }
    }

    // ---- 读取 CMBlockBuffer ----
    CMBlockBufferRef dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!dataBuffer) return;

    size_t totalLength = 0;
    char *dataPointer = NULL;
    size_t lengthAtOffset = 0;
    OSStatus err = CMBlockBufferGetDataPointer(dataBuffer, 0, &lengthAtOffset, &totalLength, &dataPointer);
    if (err != noErr || !dataPointer || totalLength == 0) {
        NSLog(@"CMBlockBufferGetDataPointer error: %d", (int)err);
        return;
    }
    const uint8_t *buf = (const uint8_t *)dataPointer;

    // 使用从 formatDesc 读到的 nal length（默认 4）
    int nalHeaderLen = vc.nalUnitLength > 0 ? vc.nalUnitLength : 4;

    // ---- 先扫描一次，判断是否包含 IDR (nal type == 5) ----
    BOOL foundIDR = NO;
    size_t scanOffset = 0;
    while (scanOffset + nalHeaderLen <= totalLength) {
        uint32_t nalLength = 0;
        if (nalHeaderLen == 4) {
            uint32_t tmp = 0;
            memcpy(&tmp, buf + scanOffset, 4);
            nalLength = CFSwapInt32BigToHost(tmp);
        } else {
            nalLength = 0;
            for (int i = 0; i < nalHeaderLen; i++) {
                nalLength = (nalLength << 8) | buf[scanOffset + i];
            }
        }
        scanOffset += nalHeaderLen;
        if (nalLength == 0 || scanOffset + nalLength > totalLength) break;
        uint8_t nalType = buf[scanOffset] & 0x1F;
        if (nalType == 5) { foundIDR = YES; break; }
        scanOffset += nalLength;
    }

    // ---- 构造输出 Annex-B 数据 ----
    NSMutableData *outData = [NSMutableData data];
    const uint8_t startCode4[4] = {0x00,0x00,0x00,0x01};

    // 如果有 IDR，且我们已有 SPS/PPS，则在前面发送 SPS/PPS（保证 dec 有参数集）
    if (foundIDR && vc.spsData && vc.ppsData) {
        [outData appendBytes:startCode4 length:4];
        [outData appendData:vc.spsData];
        [outData appendBytes:startCode4 length:4];
        [outData appendData:vc.ppsData];
    }

    // 把 AVCC length-prefixed 转为 Annex-B
    size_t offset = 0;
    while (offset + nalHeaderLen <= totalLength) {
        uint32_t nalLength = 0;
        if (nalHeaderLen == 4) {
            uint32_t tmp = 0;
            memcpy(&tmp, buf + offset, 4);
            nalLength = CFSwapInt32BigToHost(tmp);
        } else {
            nalLength = 0;
            for (int i = 0; i < nalHeaderLen; i++) {
                nalLength = (nalLength << 8) | buf[offset + i];
            }
        }
        offset += nalHeaderLen;
        if (nalLength == 0) continue;
        if (offset + nalLength > totalLength) {
            NSLog(@"NAL length overrun: offset=%zu nalLength=%u total=%zu", offset, nalLength, totalLength);
            break;
        }
        [outData appendBytes:startCode4 length:4];
        [outData appendBytes:buf + offset length:nalLength];
        offset += nalLength;
    }

    // debug: 打印前 32 字节 hex，观察是否是 00 00 00 01 67 ... 00 00 00 01 68 ... 00 00 00 01 65 ...
    size_t show = MIN((size_t)32, outData.length);
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *o = outData.bytes;
    for (size_t i = 0; i < show; i++) {
        [hex appendFormat:@"%02x ", o[i]];
    }
    NSLog(@"-> send h264 len:%lu first:%@", (unsigned long)outData.length, hex);

    // 发送
    if (outData.length > 0) {
        dispatch_async(vc.socketQueue, ^{
            if (vc.socket && vc.socket.isConnected) {
                [vc.socket writeData:outData withTimeout:-1 tag:0];
            }
        });
    }
}

- (void)startCompressionSessionWithWidth:(int)w height:(int)h fps:(int)fps bitrate:(int)bitrate {
    if (self.compressionSession) {
        [self stopCompressionSession];
    }
    self.width = w;
    self.height = h;
    self.spsData = nil;
    self.ppsData = nil;
    self.frameCount = 0;
    
    OSStatus status = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264, NULL, NULL, NULL, compressionOutputCallback, (__bridge void *)self, &_compressionSession);
    if (status != noErr) {
        NSLog(@"VTCompressionSessionCreate failed: %d", (int)status);
        return;
    }
    
    // 设置实时编码、码率、帧率、关键帧间隔等
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    
    // 码率设置（平均码率）
    CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberIntType, &bitrate);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);
    
    // 设置最大码率（可以是平均的 1.5x）
    int maxBitrate = bitrate * 2;
    CFNumberRef maxbRef = CFNumberCreate(NULL, kCFNumberIntType, &maxBitrate);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_DataRateLimits, maxbRef); // bytes per second? documentation nuance - deprecated in some versions
    CFRelease(maxbRef);
    
    // 关键帧间隔（GOP size）
    int keyFrameInterval = fps * 1; // 每秒一个 I 帧（这里设置为 1 秒）可调整
    CFNumberRef kfiRef = CFNumberCreate(NULL, kCFNumberIntType, &keyFrameInterval);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, kfiRef);
    CFRelease(kfiRef);
    
    // 期望帧率
    CFNumberRef fpsRef = CFNumberCreate(NULL, kCFNumberIntType, &fps);
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);
    
    // 配置 profile(level)
    CFStringRef profile = kVTProfileLevel_H264_Baseline_AutoLevel; // 可改为 Main 或 High
    VTSessionSetProperty(self.compressionSession, kVTCompressionPropertyKey_ProfileLevel, profile);
    
    // 准备编码
    VTCompressionSessionPrepareToEncodeFrames(self.compressionSession);
    NSLog(@"Started H264 compressor: %dx%d @%dfps bitrate:%d", w, h, fps, bitrate);
}

- (void)stopCompressionSession {
    if (!self.compressionSession) return;
    VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
    VTCompressionSessionInvalidate(self.compressionSession);
    CFRelease(self.compressionSession);
    self.compressionSession = NULL;
    self.spsData = nil;
    self.ppsData = nil;
    NSLog(@"Stopped compression session");
}

#pragma mark - UIImage -> CVPixelBuffer -> Encode
- (void)encodeUIImage:(UIImage *)image atFrame:(NSInteger)frameIndex {
    if (!self.compressionSession) return;
    
    // 确保尺寸匹配（如果 image 与 session 尺寸不同，可缩放）
    int targetW = self.width;
    int targetH = self.height;
    
    // 创建 CVPixelBuffer (BGRA)
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @(YES),
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @(YES),
        (id)kCVPixelBufferWidthKey: @(targetW),
        (id)kCVPixelBufferHeightKey: @(targetH),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn cvErr = CVPixelBufferCreate(kCFAllocatorDefault, targetW, targetH, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    if (cvErr != kCVReturnSuccess || !pixelBuffer) {
        NSLog(@"CVPixelBufferCreate failed: %d", cvErr);
        return;
    }
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    // 创建 CGContext 绘制 UIImage 到 pixelBuffer
    CGContextRef context = CGBitmapContextCreate(pxdata, targetW, targetH, 8, bytesPerRow, rgbColorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (!context) {
        NSLog(@"CGBitmapContextCreate failed");
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        CGColorSpaceRelease(rgbColorSpace);
        return;
    }
    // UIKit 的坐标系与 CoreGraphics 不同，需要翻转
    CGContextTranslateCTM(context, 0, targetH);
    CGContextScaleCTM(context, 1.0, -1.0);
    
    // draw image (按比例缩放铺满)
    CGImageRef cgImage = image.CGImage;
    CGRect drawRect = CGRectMake(0, 0, targetW, targetH);
    CGContextDrawImage(context, drawRect, cgImage);
    
    // 清理
    CGContextRelease(context);
    CGColorSpaceRelease(rgbColorSpace);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    // 时间戳
    CMTime pts = CMTimeMake(self.frameCount, 30); // frameCount 已在主线程递增
    CMTime duration = CMTimeMake(1, 30);
    
    // Encode
    VTEncodeInfoFlags flags;
    OSStatus status = VTCompressionSessionEncodeFrame(self.compressionSession,
                                                     pixelBuffer,
                                                     pts,
                                                     duration,
                                                     NULL, // frameProperties
                                                     NULL, // sourceFrameRefCon
                                                     &flags);
    if (status != noErr) {
        NSLog(@"VTCompressionSessionEncodeFrame failed: %d", (int)status);
    }
    
    // release
    CVPixelBufferRelease(pixelBuffer);
}

@end
