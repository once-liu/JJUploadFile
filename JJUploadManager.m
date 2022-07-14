//
//  JJUploadManager.m
//  KKTV
//
//  Created by macmini on 2022/7/13.
//

#import "JJUploadManager.h"


@interface JJUploadManager () <NSURLSessionDelegate>

@property (strong, nonatomic) NSURLSession *session;

@property (nonatomic, assign) BOOL isCancel;

@property (strong, nonatomic) NSMutableArray <JJFile *>*files;
//正在上传中的任务
@property (nonatomic, strong) NSMutableDictionary <NSNumber *, NSURLSessionUploadTask *> *uploadingTasks;

@end


@implementation JJUploadManager

+ (JJUploadManager *)sharedManager {
    static JJUploadManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[JJUploadManager alloc] init];
    });
    return manager;
}

// 并发上传核心方法
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
            
            // 上传分片
            @autoreleasepool {
                __weak typeof(self) weakSelf = self;
                NSData *subData = [self readFile:filePath model:file];
                [self uploadChunk:file.fileId data:subData completion:^(BOOL success, NSError * _Nullable error) {
                    if (!error) {
                        if (success) {
                            file.finish = YES;
                            [weakSelf.files removeObject:file];
                        } else {
                            file.finish = NO;
                        }
                        
                        // progress
                        // progress = (tmpArr.count - weakSelf.files.count) * 1.0 / tmpArr.count
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


/// 上传数据
/// @param chunk 分片数
/// @param data 分片的数据段
/// @param completion 回调
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
    
    [self.uploadingTasks setObject:task forKey:@(chunk)];
    
    [task resume];
}

// 取消上传
- (void)cancelUpload {
    self.isCancel = YES;
    for (NSURLSessionUploadTask *task in self.uploadingTasks) {
        [task suspend];
        [task cancel];
    }
}


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

- (nullable NSData *)readFile:(NSString *)filePath model:(JJFile *)model {
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingAtPath:filePath];
    [fileHandle seekToFileOffset:model.offset];
    return [fileHandle readDataOfLength:model.size];
}


// MARK: - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
    
}

// MARK: - Getter

- (NSURLSession *)session {
    if (!_session) {
        // default 方法，可以使用缓存的 Cache、Cookie、鉴权
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        // 允许使用蜂窝网络
        configuration.allowsCellularAccess = YES;
        
        _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[[NSOperationQueue alloc] init]];
    }
    return _session;
}

@end



@implementation JJFile


@end
