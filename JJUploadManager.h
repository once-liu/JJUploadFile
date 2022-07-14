//
//  JJUploadManager.h
//  KKTV
//
//  Created by macmini on 2022/7/13.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JJUploadManager : NSObject

@end



@interface JJFile : NSObject

@property (nonatomic, assign) NSInteger fileId;
@property (nonatomic, assign) NSInteger size;   /// 分片大小
@property (nonatomic, assign) NSInteger offset; /// 分片偏移量
@property (nonatomic, assign) BOOL finish;      /// 分片是否上传完成

@end

NS_ASSUME_NONNULL_END
