# JJUploadFile
# 场景
在上传大文件（比如视频文件）时，要考虑文件上传失败的情况。如果直接上传整个文件，在上传途中失败的话，再次上传时还需要上传已经上传过的内容。
另外，大文件加载到内存中，也可能导致 OOM 问题。

可以采用文件分片的方法解决这些问题。比如把大文件分成 1024 * 1024 Byte 大小的分段。然后上传每个分段，由接收文件的服务端进行拼接。当数据上传失败或取消，需要重新上传时，只需上传失败的分段和还未上传的分段即可。

# 设计思想
文件上传前先对文件进行分片，分片的大小可以和接收文件的服务端进行沟通，确定分片大小。对每一个分片进行上传。

分片上传时可以采用串行上传，即一个分片上传成功后再上传下一个分片，直到所有分片上传完成。也可以采用并行上传，并行上传等待时间比串行要短，但要注意并发线程数不要过多。并行情况下对上传失败的分片的处理比串行情况下略微复杂。因为并行情况下，需要等到最后一个分片上传结果后，才能对失败的分片进行处理。
分片上传与下载的断点续传操作不同。断点续传可以使用系统的实现，会在一个临时文件中进行拼接，然后等待下载完成的通知，再把临时文件中拼接好的数据拷贝别的文件路径即可。分片上传在并发情况下，需要自己确定上传完成的时刻。

上传使用的网络类为 NSURLSession，方便直接设置 POST、PUT、DELETE 等方法。上传文件使用 NSURLSessionUploadTask，支持后台传输。其他接口调用使用 NSURLSessionDataTask。
分片上传使用 Manager 类来管理上传操作。
分片上传使用并发进行上传，考虑到所有分片上传后，最后需要处理上传失败的分片，使用 GCD 的 group 和 semaphore 配合使用。

# 操作步骤
1. 选取大文件
2. 对大文件进行分片
3. 上传分片文件
4. 如果有上传失败的文件，重新上传
5. 全部上传后的处理

## 对文件进行分片
对文件进行分片，分片信息使用 model 来保存。

分片信息 model：
```
@interface JJFile : NSObject

@property (nonatomic, assign) NSInteger fileId;
@property (nonatomic, assign) NSInteger size;   /// 分片大小
@property (nonatomic, assign) NSInteger offset; /// 分片偏移量
@property (nonatomic, assign) BOOL finish;      /// 分片是否上传完成

@end
```

对数据进行分段：
```
- (void)chunkFile:(NSInteger)fileSize {
    // 分片大小
    NSInteger size = 1024 * 1024;  // 1MB
    // 总分片数
    NSInteger chunkCount = (fileSize % size == 0) ? (fileSize / size) : (fileSize / size + 1);
    
    NSMutableArray *files = [NSMutableArray arrayWithCapacity:chunkCount];
    for (NSInteger i = 0; i < chunkCount; i++) {
        JJFile *file = [[JJFile alloc] init];
        file.fileId = i + 1;
        file.offset = i * size;
        file.size = size;
        if (i == chunkCount - 1) {
            file.size = fileSize - file.offset;
        }
        file.finish = NO;
        
        [files addObject:file];
    }
}
```

读取分段对应的数据：
```
- (nullable NSData *)readFile:(NSString *)filePath model:(JJFile *)model {
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    [fileHandle seekToFileOffset:model.offset];
    
    return [fileHandle readDataOfLength:model.size];
}
```

## 上传数据
配置 NSURLSession
```
- (NSURLSession *)session {
    if (!_session) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        // 允许使用蜂窝网络
        configuration.allowsCellularAccess = YES;
        
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[[NSOperationQueue alloc] init]];
    }
    return _session;
}
```
上传任务使用 NSURLSessionUploadTask，不管有多少个 task，只需初始化一个 NSURLSession。

数据上传使用 NSURLSessionUploadTask 类来处理。每一次上传都是一个 Task。
```
- (void)uploadChunk:(NSInteger)chunk data:(NSData *)data completion:(void(^)(BOOL success, NSError * _Nullable error))completion {
    NSString *url = @"";

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setHTTPMethod:@"PATCH"];
    [request setHTTPBody:data];
    [request addValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    
    NSURLSessionUploadTask *task = [self.session uploadTaskWithRequest:request fromData:data completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        
        NSHTTPURLResponse *urlResponse = (NSHTTPURLResponse *)response;
        NSInteger code = urlResponse.statusCode;
        
        if (code == 200) {
            // 分片上传成功
            if (completion) {
                completion(YES, nil);
            }
        } else {
            if (completion) {
                completion(NO, error);
            }
        }
    }];
    
    [task resume];
}
```

上传的相关回调可以实现相应的代理方法：
```
// MARK: - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    
}
```

## 并发上传文件
```
// 并发处理的核心
- (void)uploadFile:(NSString *)filePath {
    if (!filePath) return;
    if (!self.files.count) return;
    
    int concurrentCount = 5;
    // 并发 5 个
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(concurrentCount);
    // 通过 notify 处理上传完成后续
    dispatch_group_t group = dispatch_group_create();
    // 子线程上传，避免阻塞主线程
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
    NSArray <JJFile *> *tmpArr = [NSArray arrayWithArray:self.files];
    for (JJFile *file in tmpArr) {
        dispatch_group_enter(group);
        dispatch_group_async(group, queue, ^{
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            @autoreleasepool {
                __weak typeof(self) weakSelf = self;
                 
                // 上传分片
                NSData *subData = [self readFile:filePath model:file];
                [self uploadChunk:file.fileId data:subData completion:^(BOOL success, NSError * _Nullable error) {
                    if (!error) {
                        if (success) {
                            file.finish = YES;
                            [weakSelf.files removeObject:file];
                        } else {
                            file.finish = NO;
                        }
                    }
                    dispatch_semaphore_signal(semaphore);
                    dispatch_group_leave(group);
                }];
            }
        });
    }
    
    // 第一次 for 结束。所有分片执行完上传操作
    dispatch_group_notify(group, queue, ^{
        if (self.files.count != 0) {
            // 失败重传
            [self uploadFile:filePath];
        } else {
            // 通知 server，文件全部上传完成
        }
    });
}
```

# 附加
也可以使用 NSURLSessionUploadTask 直接上传一大段数据（相册中数据大小 58MB，系统压缩后为 26MB）。NSURLSessionUploadTask支持后台上传，会对数据进行切片分段上传。
```
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    NSLog(@"🥎 byteSent: %ld, totalByte: %ld, totalToSend: %ld", bytesSent, totalBytesSent, totalBytesExpectedToSend);
}

// log
/**
 🥎 byteSent: 1572864, totalByte: 1572864, totalToSend: 27734470 
 🥎 byteSent: 1048576, totalByte: 2621440, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 3145728, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 3670016, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 4194304, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 4718592, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 5242880, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 5767168, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 6291456, totalToSend: 27734470 
 ......
 
 🥎 byteSent: 524288, totalByte: 9961472, totalToSend: 27734470 
 🥎 byteSent: 1048576, totalByte: 11010048, totalToSend: 27734470 
 ......
 
 🥎 byteSent: 524288, totalByte: 26738688, totalToSend: 27734470 
 🥎 byteSent: 524288, totalByte: 27262976, totalToSend: 27734470 
 🥎 byteSent: 471494, totalByte: 27734470, totalToSend: 27734470
*/
```

可以看到，分段数据量基本 524288 和 1048576 Bytes。 524288 Bytes 是 512KB，也就是 0.5MB。1048576 Bytes 是 1MB。





