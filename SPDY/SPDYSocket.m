//
//  SPDYSocket.m
//  SPDY
//
//  Copyright (c) 2014 Twitter, Inc. All rights reserved.
//  Licensed under the Apache License v2.0
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Substantially based on the CocoaAsyncSocket library, originally
//  created by Dustin Voss, and currently maintained at
//  https://github.com/robbiehanson/CocoaAsyncSocket
//

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import "SPDYDefinitions.h"
#import "SPDYSocket.h"
#import "SPDYCommonLogger.h"
#import "SPDYOrigin.h"
#import "SPDYOriginEndpoint.h"
#import "SPDYOriginEndpointManager.h"
#import "SPDYSocket.h"
#import "SPDYSocketOps.h"

#pragma mark Declarations

#define READ_QUEUE_CAPACITY  64    // Initial capacity
#define WRITE_QUEUE_CAPACITY 64    // Initial capacity
#define WRITE_CHUNK_SIZE     2852  // Limit on size of each write pass

#define DEBUG_THREAD_SAFETY 0

#if DEBUG_THREAD_SAFETY
#define CHECK_THREAD_SAFETY() \
do { \
    if (_runLoop && _runLoop != CFRunLoopGetCurrent()) { \
        [NSException raise:SPDYSocketException \
                    format:@"Detected SPDYSocket access from wrong RunLoop"]; \
    } \
} while (0)
#else
#define CHECK_THREAD_SAFETY()
#endif

NSString *const SPDYSocketException = @"SPDYSocketException";

typedef enum : uint16_t {
    kDidStartDelegate        = 1 <<  0,  // If set, disconnection results in delegate call
    kDidCompleteOpenForRead  = 1 <<  1,  // If set, open callback has been called for read stream
    kDidCompleteOpenForWrite = 1 <<  2,  // If set, open callback has been called for write stream
    kStartingReadTLS         = 1 <<  3,  // If set, we're waiting for TLS negotiation to complete
    kStartingWriteTLS        = 1 <<  4,  // If set, we're waiting for TLS negotiation to complete
    kForbidReadsWrites       = 1 <<  5,  // If set, no new reads or writes are allowed
    kDisconnectAfterReads    = 1 <<  6,  // If set, disconnect after no more reads are queued
    kDisconnectAfterWrites   = 1 <<  7,  // If set, disconnect after no more writes are queued
    kClosingWithError        = 1 <<  8,  // If set, the socket is being closed due to an error
    kDequeueReadScheduled    = 1 <<  9,  // If set, a _dequeueRead operation is already scheduled
    kDequeueWriteScheduled   = 1 << 10,  // If set, a _dequeueWrite operation is already scheduled
    kSocketCanAcceptBytes    = 1 << 11,  // If set, we know socket can accept bytes. If unset, it's unknown.
    kSocketHasBytesAvailable = 1 << 12,  // If set, we know socket has bytes available. If unset, it's unknown.
    kConnectingToProxy       = 1 << 13,  // If set, a proxy connection is in progress
} SPDYSocketFlag;

@interface SPDYSocket ()
{
    in_port_t _connectedPort;
    NSString *_connectedHost;
}

// Connecting
- (bool)_connectToNextEndpointWithError:(NSError **)error;
- (void)_startConnectTimeout:(NSTimeInterval)timeout;
- (void)_endConnectTimeout;
- (void)_timeoutConnect:(NSTimer *)timer;

// Stream Implementation
- (bool)_createStreamsToHost:(NSString *)hostname onPort:(in_port_t)port error:(NSError **)pError;
- (bool)_scheduleStreamsOnRunLoop:(NSRunLoop *)runLoop error:(NSError **)pError;
- (bool)_configureStreams:(NSError **)pError;
- (bool)_openStreams:(NSError **)pError;
- (void)_onStreamOpened;
- (bool)_setSocketViaStreams:(NSError **)pError;

// Disconnect Implementation
- (void)_closeWithError:(NSError *)error;
- (void)_captureUnreadData;
- (void)_emptyQueues;
- (void)_close;

// Errors
- (NSError *)abortError;
- (NSError *)streamError;
- (NSError *)connectTimeoutError;
- (NSError *)readTimeoutError;
- (NSError *)writeTimeoutError;

// Diagnostics
- (bool)_fullyDisconnected;
- (void)_setConnectionProperties;

// Reading
- (void)_read;
- (void)_finishRead;
- (void)_endRead;
- (void)_scheduleRead;
- (void)_dequeueRead;
- (void)_timeoutRead:(NSTimer *)timer;

// Writing
- (void)_write;
- (void)_finishWrite;
- (void)_endWrite;
- (void)_scheduleWrite;
- (void)_dequeueWrite;
- (void)_timeoutWrite:(NSTimer *)timer;

// CFRunLoop scheduling
- (void)_addSource:(CFRunLoopSourceRef)source;
- (void)_addTimer:(NSTimer *)timer;
- (void)_removeSource:(CFRunLoopSourceRef)source;
- (void)_removeTimer:(NSTimer *)timer;
- (void)_scheduleDisconnect;
- (void)_unscheduleReadStream;
- (void)_unscheduleWriteStream;

// TLS
- (void)_tryTLSHandshake;
- (void)_onTLSHandshakeSuccess;

// Callbacks
- (void)handleCFReadStreamEvent:(CFStreamEventType)type forStream:(CFReadStreamRef)stream;
- (void)handleCFWriteStreamEvent:(CFStreamEventType)type forStream:(CFWriteStreamRef)stream;

@end

static void SPDYSocketCFReadStreamCallback(CFReadStreamRef stream, CFStreamEventType type, void *pInfo);
static void SPDYSocketCFWriteStreamCallback(CFWriteStreamRef stream, CFStreamEventType type, void *pInfo);


@implementation SPDYSocket
{
    CFSocketNativeHandle _socket4FD;
    CFSocketNativeHandle _socket6FD;

    CFSocketRef _socket4; // IPv4
    CFSocketRef _socket6; // IPv6

    CFReadStreamRef _readStream;
    CFWriteStreamRef _writeStream;

    CFRunLoopSourceRef _source4; // For _socket4
    CFRunLoopSourceRef _source6; // For _socket6
    CFRunLoopRef _runLoop;
    CFSocketContext _context;
    NSArray *_runLoopModes;

    NSTimer *_connectTimer;

    NSMutableArray *_readQueue;
    SPDYSocketReadOp *_currentReadOp;
    NSTimer *_readTimer;
    NSMutableData *_unreadData;

    NSMutableArray *_writeQueue;
    SPDYSocketWriteOp *_currentWriteOp;
    NSTimer *_writeTimer;

    id<SPDYSocketDelegate> _delegate;
    uint16_t _flags;

    SPDYOriginEndpointManager *_endpointManager;
}

- (instancetype)init
{
    return [self initWithDelegate:nil];
}

- (instancetype)initWithDelegate:(id<SPDYSocketDelegate>)delegate
{
    self = [super init];
    if (self) {
        _delegate = delegate;
        _flags = (uint16_t)0;
        _socket4FD = 0;
        _socket6FD = 0;
        _readQueue = [[NSMutableArray alloc] initWithCapacity:READ_QUEUE_CAPACITY];
        _writeQueue = [[NSMutableArray alloc] initWithCapacity:WRITE_QUEUE_CAPACITY];
        _runLoopModes = @[NSDefaultRunLoopMode];

        NSAssert(sizeof(CFSocketContext) == sizeof(CFStreamClientContext), @"CFSocketContext != CFStreamClientContext");
        _context.version = 0;
        _context.info = (__bridge void *)(self);
        _context.retain = nil;
        _context.release = nil;
        _context.copyDescription = nil;
    }
    return self;
}

- (void)dealloc
{
    [self _close];
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
}


#pragma mark Accessors

- (id<SPDYSocketDelegate>)delegate
{
    CHECK_THREAD_SAFETY();

    return _delegate;
}

- (void)setDelegate:(id<SPDYSocketDelegate>)delegate
{
    CHECK_THREAD_SAFETY();

    _delegate = delegate;
}

- (CFSocketRef)cfSocket
{
    CHECK_THREAD_SAFETY();

    return _socket4 ?: _socket6;
}

- (CFReadStreamRef)cfReadStream
{
    CHECK_THREAD_SAFETY();

    return _readStream;
}

- (CFWriteStreamRef)cfWriteStream
{
    CHECK_THREAD_SAFETY();

    return _writeStream;
}


#pragma mark CFRunLoop scheduling

- (void)_addSource:(CFRunLoopSourceRef)source
{
    for (NSString *runLoopMode in _runLoopModes) {
        CFRunLoopAddSource(_runLoop, source, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)_removeSource:(CFRunLoopSourceRef)source
{
    for (NSString *runLoopMode in _runLoopModes) {
        CFRunLoopRemoveSource(_runLoop, source, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)_addSource:(CFRunLoopSourceRef)source mode:(NSString *)runLoopMode
{
    CFRunLoopAddSource(_runLoop, source, (__bridge CFStringRef)runLoopMode);
}

- (void)_removeSource:(CFRunLoopSourceRef)source mode:(NSString *)runLoopMode
{
    CFRunLoopRemoveSource(_runLoop, source, (__bridge CFStringRef)runLoopMode);
}

- (void)_addTimer:(NSTimer *)timer
{
    for (NSString *runLoopMode in _runLoopModes) {
        CFRunLoopAddTimer(_runLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)_removeTimer:(NSTimer *)timer
{
    for (NSString *runLoopMode in _runLoopModes) {
        CFRunLoopRemoveTimer(_runLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
    }
}

- (void)_addTimer:(NSTimer *)timer mode:(NSString *)runLoopMode
{
    CFRunLoopAddTimer(_runLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
}

- (void)_removeTimer:(NSTimer *)timer mode:(NSString *)runLoopMode
{
    CFRunLoopRemoveTimer(_runLoop, (__bridge CFRunLoopTimerRef)timer, (__bridge CFStringRef)runLoopMode);
}

- (void)_unscheduleReadStream
{
    for (NSString *runLoopMode in _runLoopModes) {
        CFReadStreamUnscheduleFromRunLoop(_readStream, _runLoop, (__bridge CFStringRef)runLoopMode);
    }
    CFReadStreamSetClient(_readStream, kCFStreamEventNone, NULL, NULL);
}

- (void)_unscheduleWriteStream
{
    for (NSString *runLoopMode in _runLoopModes) {
        CFWriteStreamUnscheduleFromRunLoop(_writeStream, _runLoop, (__bridge CFStringRef)runLoopMode);
    }
    CFWriteStreamSetClient(_writeStream, kCFStreamEventNone, NULL, NULL);
}


#pragma mark Configuration

- (bool)setRunLoop:(NSRunLoop *)runLoop
{
    NSAssert(_runLoop == NULL || _runLoop == CFRunLoopGetCurrent(),
    @"moveToRunLoop must be called from within the current RunLoop!");

    if (runLoop == nil) {
        return NO;
    }
    if (_runLoop == [runLoop getCFRunLoop]) {
        return YES;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _flags &= ~kDequeueReadScheduled;
    _flags &= ~kDequeueWriteScheduled;

    if (_readStream && _writeStream) {
        [self _unscheduleReadStream];
        [self _unscheduleWriteStream];
    }

    if (_source4) [self _removeSource:_source4];
    if (_source6) [self _removeSource:_source6];

    if (_readTimer) [self _removeTimer:_readTimer];
    if (_writeTimer) [self _removeTimer:_writeTimer];

    _runLoop = [runLoop getCFRunLoop];

    if (_readTimer) [self _addTimer:_readTimer];
    if (_writeTimer) [self _addTimer:_writeTimer];

    if (_source4) [self _addSource:_source4];
    if (_source6) [self _addSource:_source6];

    if (_readStream && _writeStream) {
        if (![self _scheduleStreamsOnRunLoop:runLoop error:nil]) {
            return NO;
        }
    }

    [runLoop performSelector:@selector(_dequeueRead) target:self argument:nil order:0 modes:_runLoopModes];
    [runLoop performSelector:@selector(_dequeueWrite) target:self argument:nil order:0 modes:_runLoopModes];
    [runLoop performSelector:@selector(_scheduleDisconnect) target:self argument:nil order:0 modes:_runLoopModes];

    return YES;
}

- (bool)setRunLoopModes:(NSArray *)runLoopModes
{
    NSAssert(_runLoop == NULL || _runLoop == CFRunLoopGetCurrent(),
    @"setRunLoopModes must be called from within the current RunLoop!");

    if (runLoopModes.count == 0) {
        return NO;
    }
    if ([_runLoopModes isEqualToArray:runLoopModes]) {
        return YES;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _flags &= ~kDequeueReadScheduled;
    _flags &= ~kDequeueWriteScheduled;

    if (_readStream && _writeStream) {
        [self _unscheduleReadStream];
        [self _unscheduleWriteStream];
    }

    if (_source4) [self _removeSource:_source4];
    if (_source6) [self _removeSource:_source6];

    if (_readTimer) [self _removeTimer:_readTimer];
    if (_writeTimer) [self _removeTimer:_writeTimer];

    _runLoopModes = [runLoopModes copy];

    if (_readTimer) [self _addTimer:_readTimer];
    if (_writeTimer) [self _addTimer:_writeTimer];

    if (_source4) [self _addSource:_source4];
    if (_source6) [self _addSource:_source6];

    if (_readStream && _writeStream) {
        if (![self _scheduleStreamsOnRunLoop:nil error:nil]) {
            return NO;
        }
    }

    [self performSelector:@selector(_dequeueRead) withObject:nil afterDelay:0 inModes:_runLoopModes];
    [self performSelector:@selector(_dequeueWrite) withObject:nil afterDelay:0 inModes:_runLoopModes];
    [self performSelector:@selector(_scheduleDisconnect) withObject:nil afterDelay:0 inModes:_runLoopModes];

    return YES;
}

- (bool)addRunLoopMode:(NSString *)runLoopMode
{
    NSAssert(_runLoop == NULL || _runLoop == CFRunLoopGetCurrent(),
    @"addRunLoopMode must be called from within the current RunLoop!");

    if (runLoopMode == nil) {
        return NO;
    }
    if ([_runLoopModes containsObject:runLoopMode]) {
        return YES;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _flags &= ~kDequeueReadScheduled;
    _flags &= ~kDequeueWriteScheduled;

    NSArray *newRunLoopModes = [_runLoopModes arrayByAddingObject:runLoopMode];
    _runLoopModes = newRunLoopModes;

    if (_readTimer) [self _addTimer:_readTimer mode:runLoopMode];
    if (_writeTimer) [self _addTimer:_writeTimer mode:runLoopMode];

    if (_source4) [self _addSource:_source4 mode:runLoopMode];
    if (_source6) [self _addSource:_source6 mode:runLoopMode];

    if (_readStream && _writeStream) {
        CFReadStreamScheduleWithRunLoop(_readStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
        CFWriteStreamScheduleWithRunLoop(_writeStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
    }

    [self performSelector:@selector(_dequeueRead) withObject:nil afterDelay:0 inModes:_runLoopModes];
    [self performSelector:@selector(_dequeueWrite) withObject:nil afterDelay:0 inModes:_runLoopModes];
    [self performSelector:@selector(_scheduleDisconnect) withObject:nil afterDelay:0 inModes:_runLoopModes];

    return YES;
}

- (bool)removeRunLoopMode:(NSString *)runLoopMode
{
    NSAssert(_runLoop == NULL || _runLoop == CFRunLoopGetCurrent(),
    @"addRunLoopMode must be called from within the current RunLoop!");

    if (runLoopMode == nil) {
        return NO;
    }
    if (![_runLoopModes containsObject:runLoopMode]) {
        return YES;
    }

    NSMutableArray *newRunLoopModes = [_runLoopModes mutableCopy];
    [newRunLoopModes removeObject:runLoopMode];

    if (newRunLoopModes.count == 0) {
        return NO;
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    _flags &= ~kDequeueReadScheduled;
    _flags &= ~kDequeueWriteScheduled;

    _runLoopModes = [newRunLoopModes copy];

    if (_readTimer) [self _removeTimer:_readTimer mode:runLoopMode];
    if (_writeTimer) [self _removeTimer:_writeTimer mode:runLoopMode];

    if (_source4) [self _removeSource:_source4 mode:runLoopMode];
    if (_source6) [self _removeSource:_source6 mode:runLoopMode];

    if (_readStream && _writeStream) {
        CFReadStreamScheduleWithRunLoop(_readStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
        CFWriteStreamScheduleWithRunLoop(_writeStream, CFRunLoopGetCurrent(), (__bridge CFStringRef)runLoopMode);
    }

    [self performSelector:@selector(_dequeueRead) withObject:nil afterDelay:0 inModes:_runLoopModes];
    [self performSelector:@selector(_dequeueWrite) withObject:nil afterDelay:0 inModes:_runLoopModes];
    [self performSelector:@selector(_scheduleDisconnect) withObject:nil afterDelay:0 inModes:_runLoopModes];

    return YES;
}

- (NSArray *)runLoopModes
{
    CHECK_THREAD_SAFETY();

    return _runLoopModes;
}


#pragma mark Connecting

/**
  Attempts to connect to the given host and port.

  The delegate will have access to the CFReadStream and CFWriteStream prior to connection,
  specifically in the socketWillConnect: method.
*/
- (bool)connectToOrigin:(SPDYOrigin *)origin
            withTimeout:(NSTimeInterval)timeout
                  error:(NSError **)pError
{
    if (_delegate == nil) {
        [NSException raise:SPDYSocketException
                    format:@"Attempting to connect without a delegate. Set a delegate first."];
    }

    if (![self _fullyDisconnected]) {
        [NSException raise:SPDYSocketException
                    format:@"Attempting to connect while connected or accepting connections. Disconnect first."];
    }

    [self _emptyQueues];

    if (_runLoop == nil) {
        // Need to set this before _startConnectTimeout
        _runLoop = CFRunLoopGetCurrent();
    }

    [self _startConnectTimeout:timeout];

    // Clear all flags
    _flags = (uint16_t)0;

    if (_endpointManager == nil) {
        _endpointManager = [[SPDYOriginEndpointManager alloc] initWithOrigin:origin];
    }

    // This block may run synchronously, if there is no work to do to resolve the endpoints.
    // If there is, it will be scheduled on the current runloop and run asynchronously. For
    // the case where it runs synchronously but fails, we need to know that in order to inform
    // the session properly.
    BOOL __block success = YES;
    NSError __block *error = nil;
    __typeof__(self) __weak weakSelf = self;
    [_endpointManager resolveEndpointsWithCompletionHandler:^{
        __typeof__(self) strongSelf = weakSelf;
        if (strongSelf && !strongSelf.closed) {
            if (![strongSelf _connectToNextEndpointWithError:&error]) {
                success = NO;
                [strongSelf _closeWithError:error];
            }
        }
    }];

    // Starting the delegate now will catch the asynchronous case of resolveEndpointsWithCompletionHandler.
    // It will duplicate the synchronous case, as it has already been set.
    _flags |= kDidStartDelegate;

    if (pError && error) {
        *pError = error;
    }
    return success;
}

- (bool)_connectToNextEndpointWithError:(NSError **)pError
{
    // Starting the delegate now will catch the synchronous case of resolveEndpointsWithCompletionHandler,
    // and also reset to a known state for subsequent connect attempts.
    _flags = kDidStartDelegate;

    if (_currentReadOp) {
        BOOL isProxyOp = [_currentReadOp isKindOfClass:[SPDYSocketProxyReadOp class]];
        NSAssert(isProxyOp, @"expected proxy currentReadOp, is %@", _currentReadOp);
        if (!isProxyOp) {
            SPDY_ERROR(@"error connecting to endpoint %@: unexpected read state", _endpointManager.endpoint);
            if (pError && *pError == nil) {
                *pError = SPDY_SOCKET_ERROR(SPDYSocketProxyError, @"unexpected read state, unable to connect to next endpoint");
            }
            return NO;
        }
        [self _endRead];
    }

    if (_currentWriteOp) {
        BOOL isProxyOp = [_currentWriteOp isKindOfClass:[SPDYSocketProxyWriteOp class]];
        NSAssert(isProxyOp, @"expected proxy currentWrite, is %@", _currentWriteOp);
        if (!isProxyOp) {
            SPDY_ERROR(@"error connecting to endpoint %@: unexpected write state", _endpointManager.endpoint);
            if (pError && *pError == nil) {
                *pError = SPDY_SOCKET_ERROR(SPDYSocketProxyError, @"unexpected write state, unable to connect to next endpoint");
            }
            return NO;
        }
        [self _endWrite];
    }

    [self _resetStreamsAndSockets];

    SPDYOriginEndpoint *endpoint = [_endpointManager moveToNextEndpoint];
    if (endpoint == nil) {
        SPDY_INFO(@"error connecting to origin %@: no more endpoints available", _endpointManager.origin);
        if (pError && *pError == nil) {
            *pError = SPDY_SOCKET_ERROR(SPDYSocketProxyError, @"No endpoints available, unable to connect socket");
        }
        return NO;
    }

    SPDY_INFO(@"socket attempting connection to %@", _endpointManager.endpoint);

    if (![self _createStreamsToHost:endpoint.host onPort:endpoint.port error:pError] ||
            ![self _scheduleStreamsOnRunLoop:nil error:pError] ||
            ![self _configureStreams:pError] ||
            ![self _openStreams:pError]) {
        return [self _connectToNextEndpointWithError:pError];
    }

    // If connecting to an HTTPS proxy, we have to exchange an HTTP CONNECT message. This exchange
    // needs to be included in the timeout. If anything fails, we'd prefer to hide the error
    // from the app, until no more endpoints (proxy or direct) are available. Let's go start
    // the CONNECT exchange now.
    if (endpoint.type == SPDYOriginEndpointTypeHttpsProxy) {
        CHECK_THREAD_SAFETY();

        _flags |= kConnectingToProxy;

        // Issue the proxy read op. Needs to go to the head of the queue.
        SPDYSocketProxyReadOp *readOp = [[SPDYSocketProxyReadOp alloc] initWithTimeout:(NSTimeInterval)-1];
        [_readQueue insertObject:readOp atIndex:0];
        [self _scheduleRead];

        // Issue the proxy write op (CONNECT message). Needs to go to the head of the queue.
        SPDYSocketProxyWriteOp *writeOp = [[SPDYSocketProxyWriteOp alloc] initWithOrigin:endpoint.origin timeout:(NSTimeInterval)-1];
        [_writeQueue insertObject:writeOp atIndex:0];
        [self _scheduleWrite];

        SPDY_DEBUG(@"sent proxy CONNECT request");
    }

    return YES;
}

- (void)_handleError:(NSError *)rootError
{
    if (!(_flags & kConnectingToProxy)) {
        // We only support attempting the next endpoint if the current one is a proxy, and only
        // if it failed prior or during the the connection phase. This includes opening and
        // configuring the streams, establishing the TCP connection, and exchanging the CONNECT
        // message and its response. Once we reach the TLS or application-provided read/write
        // operations, no additional connection attempts are supported.
        [self _closeWithError:rootError];
    } else {
        NSError *error = nil;
        SPDY_INFO(@"socket error, attempting next connection: %@", rootError);
        if (![self _connectToNextEndpointWithError:&error]) {
            [self _closeWithError:error];
        }
    }
}

- (void)_startConnectTimeout:(NSTimeInterval)timeout
{
    if (timeout >= 0.0) {
        _connectTimer = [NSTimer timerWithTimeInterval:timeout
                                                target:self
                                              selector:@selector(_timeoutConnect:)
                                              userInfo:nil
                                               repeats:NO];
        [self _addTimer:_connectTimer];
    }
}

- (void)_endConnectTimeout
{
    [_connectTimer invalidate];
    _connectTimer = nil;
}

- (void)_timeoutConnect:(NSTimer *)timer
{
#pragma unused(timer)

    [self _endConnectTimeout];
    [self _closeWithError:[self connectTimeoutError]];
}


#pragma mark CFStream management

/**
  Creates the CFReadStream and CFWriteStream from the given hostname and port number.

  The CFSocket may be extracted from either stream after the streams have been opened.
*/
- (bool)_createStreamsToHost:(NSString *)hostname onPort:(in_port_t)port error:(NSError **)pError
{
    // All the hacky code here is almost certainly unnecessary, but we're trying to track
    // down a
    // crash in CFStreamCreatePairWithSocketToHost and grasping at straws.
    NSParameterAssert(_readStream == nil);
    NSParameterAssert(_writeStream == nil);
    NSParameterAssert(hostname.length > 0);
    _readStream = nil;
    _writeStream = nil;

    // CFStreamCreatePairWithSocketToHost does not handle nil hostnames well.
    if (hostname.length == 0) {
        return NO;
    }

    CFReadStreamRef readStreamRef = NULL;
    CFWriteStreamRef writeStreamRef = NULL;
    NSString *hostnameCopy = [hostname copy];  // force an extra retain
    CFStringRef hostnameRef = (__bridge CFStringRef)hostnameCopy;

    // No references to self in this call now, no bridges, nothing funky.
    CFStreamCreatePairWithSocketToHost(NULL, hostnameRef, port, &readStreamRef, &writeStreamRef);

    _writeStream = writeStreamRef;
    _readStream = readStreamRef;

    if (_readStream == NULL || _writeStream == NULL) {
        SPDY_ERROR(@"%@ cannot create streams to %@", self, hostname);
        if (pError) *pError = [self streamError];
        return NO;
    }

    CFReadStreamSetProperty(_readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(_writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);

    return YES;
}

- (bool)_scheduleStreamsOnRunLoop:(NSRunLoop *)runLoop error:(NSError **)pError
{
    _runLoop = runLoop ? [runLoop getCFRunLoop] : CFRunLoopGetCurrent();

    CFOptionFlags readStreamEvents =
        kCFStreamEventHasBytesAvailable |
        kCFStreamEventErrorOccurred     |
        kCFStreamEventEndEncountered    |
        kCFStreamEventOpenCompleted;

    if (!CFReadStreamSetClient(_readStream,
        readStreamEvents,
        (CFReadStreamClientCallBack)&SPDYSocketCFReadStreamCallback,
        (CFStreamClientContext *)(&_context)))
    {
        NSError *error = [self streamError];
        SPDY_WARNING(@"%@ couldn't attach read stream to run loop: %@,", self, error);

        if (pError) *pError = error;
        return NO;
    }

    CFOptionFlags writeStreamEvents =
        kCFStreamEventCanAcceptBytes |
        kCFStreamEventErrorOccurred  |
        kCFStreamEventEndEncountered |
        kCFStreamEventOpenCompleted;

    if (!CFWriteStreamSetClient(_writeStream,
        writeStreamEvents,
        (CFWriteStreamClientCallBack)&SPDYSocketCFWriteStreamCallback,
        (CFStreamClientContext *)(&_context)))
    {
        NSError *error = [self streamError];
        SPDY_WARNING(@"%@ couldn't attach write stream to run loop: %@,", self, error);

        if (pError) *pError = error;
        return NO;
    }

    for (NSString *runLoopMode in _runLoopModes) {
        CFReadStreamScheduleWithRunLoop(_readStream, _runLoop, (__bridge CFStringRef)runLoopMode);
        CFWriteStreamScheduleWithRunLoop(_writeStream, _runLoop, (__bridge CFStringRef)runLoopMode);
    }

    return YES;
}

/**
  Allows the delegate method to configure the read and/or write streams prior to connection.

  The CFSocket and CFNativeSocket will not be available until after the connection is opened.
*/
- (bool)_configureStreams:(NSError **)pError
{
    // Always called, even for proxy connections
    if ([_delegate respondsToSelector:@selector(socketWillConnect:)]) {
        if (![_delegate socketWillConnect:self]) {
            if (pError) *pError = [self abortError];
            SPDY_WARNING(@"%@ aborting connection", self);
            return NO;
        }
    }
    return YES;
}

- (bool)_openStreams:(NSError **)pError
{
    bool success = YES;

    if (success && !CFReadStreamOpen(_readStream)) {
        SPDY_WARNING(@"%@ couldn't open read stream,", self);
        success = NO;
    }

    if (success && !CFWriteStreamOpen(_writeStream)) {
        SPDY_WARNING(@"%@ couldn't open write stream,", self);
        success = NO;
    }

    if (!success) {
        if (pError) *pError = [self streamError];
    }

    return success;
}

/**
  Called when read or write streams open.
*/
- (void)_onStreamOpened
{
    if ((_flags & kDidCompleteOpenForRead) && (_flags & kDidCompleteOpenForWrite)) {
        NSError *error = nil;

        SPDY_INFO(@"socket connected to %@", _endpointManager.endpoint);

        if (_connectTimer &&
            CFAbsoluteTimeGetCurrent() >
                CFRunLoopTimerGetNextFireDate((__bridge CFRunLoopTimerRef)_connectTimer)) {

            // If the app was suspended, the connect timeout may have failed to fire
            // due to the tolerance limitations in NSTimer.

            [self _timeoutConnect:_connectTimer];
            return;
        }

        if (![self _setSocketViaStreams:&error]) {
            SPDY_ERROR(@"%@ couldn't get socket from streams, %@. Disconnecting.", self, error);
            [self _closeWithError:error];
            return;
        }

        // A non-proxy connection is finished at this point. Proxy connections still have to
        // exchange an HTTP CONNECT message.
        if (!(_flags & kConnectingToProxy)) {
            [self _endConnectTimeout];
        }

        [self _setConnectionProperties];

        if (!(_flags & kConnectingToProxy)) {
            if ([_delegate respondsToSelector:@selector(socket:didConnectToHost:port:)]) {
                [_delegate socket:self didConnectToHost:_connectedHost port:_connectedPort];
            }
        }

        [self _dequeueRead];
        [self _dequeueWrite];
    }
}

- (bool)_setSocketViaStreams:(NSError **)pError
{
    CFSocketNativeHandle native;
    CFDataRef nativeProp = CFReadStreamCopyProperty(_readStream, kCFStreamPropertySocketNativeHandle);
    if (nativeProp == NULL) {
        if (pError) *pError = [self streamError];
        return NO;
    }

    CFIndex length = MIN(CFDataGetLength(nativeProp), (CFIndex)sizeof(native));
    CFDataGetBytes(nativeProp, CFRangeMake(0, length), (uint8_t *)&native);
    CFRelease(nativeProp);

    CFSocketRef socket = CFSocketCreateWithNative(kCFAllocatorDefault, native, 0, NULL, NULL);
    if (socket == NULL) {
        if (pError) *pError = SPDY_SOCKET_ERROR(SPDYSocketCFSocketError, @"Error creating socket");
        return NO;
    }

    CFDataRef peeraddr = CFSocketCopyPeerAddress(socket);
    if (peeraddr == NULL) {
        SPDY_ERROR(@"%@ couldn't determine IP version of socket", self);

        CFRelease(socket);

        if (pError) *pError = SPDY_SOCKET_ERROR(SPDYSocketCFSocketError, @"Error getting IP address of socket");
        return NO;
    }
    struct sockaddr *sa = (struct sockaddr *)CFDataGetBytePtr(peeraddr);

    if (sa->sa_family == AF_INET) {
        _socket4 = socket;
        _socket4FD = native;
    } else {
        _socket6 = socket;
        _socket6FD = native;
    }

    CFRelease(peeraddr);

    CFBooleanRef cellularProp = CFReadStreamCopyProperty(_readStream, kCFStreamPropertyConnectionIsCellular);
    if (cellularProp != NULL) {
        _isCellular = CFBooleanGetValue(cellularProp);
        CFRelease(cellularProp);
    }

    return YES;
}


#pragma mark Disconnect Implementation

- (void)_closeWithError:(NSError *)error
{
    SPDY_INFO(@"socket closing with error: %@", error);
    NSParameterAssert(error != nil);

    _flags |= kClosingWithError;

    if (_flags & kDidStartDelegate) {
        if (!(_flags & kConnectingToProxy)) {
            [self _captureUnreadData];
        }

        // Give the delegate the opportunity to recover unread data
        if ([_delegate respondsToSelector:@selector(socket:willDisconnectWithError:)]) {
            [_delegate socket:self willDisconnectWithError:error];
        }
    }
    [self _close];
}

- (void)_resetStreamsAndSockets
{
    if (_readStream) {
        [self _unscheduleReadStream];
        CFReadStreamClose(_readStream);
        CFRelease(_readStream);
        _readStream = NULL;
    }

    if (_writeStream) {
        [self _unscheduleWriteStream];
        CFWriteStreamClose(_writeStream);
        CFRelease(_writeStream);
        _writeStream = NULL;
    }

    if (_socket4) {
        CFSocketInvalidate(_socket4);
        CFRelease(_socket4);
        _socket4 = NULL;
    }

    if (_socket6) {
        CFSocketInvalidate(_socket6);
        CFRelease(_socket6);
        _socket6 = NULL;
    }

    // Closing the streams or sockets resulted in closing the underlying native socket
    _socket4FD = 0;
    _socket6FD = 0;

    if (_source4) {
        [self _removeSource:_source4];
        CFRelease(_source4);
        _source4 = NULL;
    }

    if (_source6) {
        [self _removeSource:_source6];
        CFRelease(_source6);
        _source6 = NULL;
    }
}

- (void)_captureUnreadData
{
    if (_currentReadOp &&
        [_currentReadOp isKindOfClass:[SPDYSocketReadOp class]] &&
        _currentReadOp->_bytesRead > 0)
    {
        void const *buffer = _currentReadOp->_buffer.mutableBytes + _currentReadOp->_startOffset;
        _unreadData = [[NSMutableData alloc] initWithBytes:buffer
                                                    length:_currentReadOp->_bytesRead];
    }

    [self _emptyQueues];
}

- (void)_emptyQueues
{
    if (_currentReadOp) [self _endRead];
    if (_currentWriteOp) [self _endWrite];

    [_readQueue removeAllObjects];
    [_writeQueue removeAllObjects];

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_dequeueRead) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_dequeueWrite) object:nil];

    _flags &= ~kDequeueReadScheduled;
    _flags &= ~kDequeueWriteScheduled;
}

/**
  Disconnects. This is called for both error and clean disconnections.
*/
- (void)_close
{
    if ((_flags & kConnectingToProxy) && _endpointManager.remaining > 0) {
        SPDY_WARNING(@"socket failed connecting to proxy %@. %lu endpoints remain, but only 1 attempt is supported.",
                _endpointManager.endpoint, (unsigned long)_endpointManager.remaining);
    }

    [self _emptyQueues];

    _unreadData = nil;

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(disconnect) object:nil];

    if (_connectTimer) {
        [self _endConnectTimeout];
    }

    [self _resetStreamsAndSockets];

    _runLoop = NULL;

    // If the connection has at least been started, notify delegate that it is now ending
    if (_flags & kDidStartDelegate) {
        // Do not access any instance variables after calling onSocketDidDisconnect.
        // This gives the delegate freedom to release us without returning here and crashing.
        if ([_delegate respondsToSelector:@selector(socketDidDisconnect:)]) {
            [_delegate socketDidDisconnect:self];
        }
    }
}

/**
  Disconnects immediately. Any pending reads or writes are dropped.
*/
- (void)disconnect
{
    CHECK_THREAD_SAFETY();

    [self _close];
}

/**
  Diconnects after all pending reads have completed.
*/
- (void)disconnectAfterReads
{
    CHECK_THREAD_SAFETY();

    _flags |= (kForbidReadsWrites | kDisconnectAfterReads);
    [self _scheduleDisconnect];
}

/**
  Disconnects after all pending writes have completed.
*/
- (void)disconnectAfterWrites
{
    CHECK_THREAD_SAFETY();

    _flags |= (kForbidReadsWrites | kDisconnectAfterWrites);
    [self _scheduleDisconnect];
}

/**
  Disconnects after all pending reads and writes have completed.
*/
- (void)disconnectAfterReadsAndWrites
{
    CHECK_THREAD_SAFETY();

    _flags |= (kForbidReadsWrites | kDisconnectAfterReads | kDisconnectAfterWrites);
    [self _scheduleDisconnect];
}

- (void)_scheduleDisconnect
{
    bool shouldDisconnect = NO;

    if (_flags & kDisconnectAfterReads) {
        if (_readQueue.count == 0 && _currentReadOp == nil) {
            if (_flags & kDisconnectAfterWrites) {
                if (_writeQueue.count == 0 && _currentWriteOp == nil) {
                    shouldDisconnect = YES;
                }
            } else {
                shouldDisconnect = YES;
            }
        }
    } else if (_flags & kDisconnectAfterWrites) {
        if (_writeQueue.count == 0 && _currentWriteOp == nil) {
            shouldDisconnect = YES;
        }
    }

    if (shouldDisconnect) {
        [self performSelector:@selector(disconnect) withObject:nil afterDelay:0 inModes:_runLoopModes];
    }
}

/**
  In the event of an error, this method may be called during socket:willDisconnectWithError: to read
  any data that's left on the socket.
*/
- (NSData *)unreadData
{
    CHECK_THREAD_SAFETY();

    if (!(_flags & kClosingWithError)) return nil;

    if (_readStream == NULL) return nil;

    NSUInteger totalBytesRead = _unreadData.length;

    bool error = NO;
    while (!error && CFReadStreamHasBytesAvailable(_readStream)) {
        if (totalBytesRead == _unreadData.length) {
            [_unreadData increaseLengthBy:READ_CHUNK_SIZE];
        }

        NSUInteger bytesToRead = _unreadData.length - totalBytesRead;
        uint8_t *readBuffer = (uint8_t *)(_unreadData.mutableBytes + totalBytesRead);

        CFIndex bytesRead = CFReadStreamRead(_readStream, readBuffer, bytesToRead);

        if (bytesRead < 0) {
            error = YES;
        } else {
            totalBytesRead += bytesRead;
        }
    }

    [_unreadData setLength:totalBytesRead];

    return _unreadData;
}


#pragma mark Errors

- (NSError *)streamError
{
    CFErrorRef error;
    if (_readStream) {
        error = CFReadStreamCopyError(_readStream);
        if (error) return CFBridgingRelease(error);
    }

    if (_writeStream) {
        error = CFWriteStreamCopyError(_writeStream);
        if (error) return CFBridgingRelease(error);
    }

    return SPDY_SOCKET_ERROR(SPDYSocketTransportError, @"General socket stream error.");
}

- (NSError *)abortError
{
    NSDictionary *info = @{ NSLocalizedDescriptionKey : @"The socket connection was canceled." };
    return [NSError errorWithDomain:SPDYSocketErrorDomain code:SPDYSocketConnectCanceled userInfo:info];
}

- (NSError *)connectTimeoutError
{
    NSDictionary *info = @{ NSLocalizedDescriptionKey : @"The socket connection timed out." };
    return [NSError errorWithDomain:SPDYSocketErrorDomain code:SPDYSocketConnectTimeout userInfo:info];
}

- (NSError *)readTimeoutError
{
    NSDictionary *info = @{ NSLocalizedDescriptionKey : @"The read operation timed out." };
    return [NSError errorWithDomain:SPDYSocketErrorDomain code:SPDYSocketReadTimeout userInfo:info];
}

- (NSError *)writeTimeoutError
{
    NSDictionary *info = @{ NSLocalizedDescriptionKey : @"The write operation timed out." };
    return [NSError errorWithDomain:SPDYSocketErrorDomain code:SPDYSocketWriteTimeout userInfo:info];
}


#pragma mark State

- (bool)connected
{
    CHECK_THREAD_SAFETY();

    CFStreamStatus status;

    if (_readStream) {
        status = CFReadStreamGetStatus(_readStream);
        if (status != kCFStreamStatusOpen    &&
            status != kCFStreamStatusReading &&
            status != kCFStreamStatusError)
            return NO;
    } else {
        return NO;
    }

    if (_writeStream) {
        status = CFWriteStreamGetStatus(_writeStream);
        if (status != kCFStreamStatusOpen    &&
            status != kCFStreamStatusWriting &&
            status != kCFStreamStatusError)
            return NO;
    } else {
        return NO;
    }

    return YES;
}

- (bool)_fullyDisconnected
{
    CHECK_THREAD_SAFETY();

    return _socket4FD   == 0    &&
           _socket6FD   == 0    &&
           _socket4     == NULL &&
           _socket6     == NULL &&
           _readStream  == NULL &&
           _writeStream == NULL;
}

- (void)_setConnectionProperties
{
    CHECK_THREAD_SAFETY();

    char addrBuf[INET6_ADDRSTRLEN];

    if (_socket4FD > 0) {

        struct sockaddr_in sockaddr4;
        struct sockaddr_in *pSockaddr4 = &sockaddr4;
        socklen_t sockaddr4len = sizeof(sockaddr4);

        if (getpeername(_socket4FD, (struct sockaddr *)&sockaddr4, &sockaddr4len) >= 0 &&
            inet_ntop(AF_INET, &pSockaddr4->sin_addr, addrBuf, (socklen_t)sizeof(addrBuf)))
        {
            _connectedPort = ntohs(sockaddr4.sin_port);
            _connectedHost = [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
            return;
        }

    } else if (_socket6FD > 0) {

        struct sockaddr_in6 sockaddr6;
        struct sockaddr_in6 *pSockaddr6 = &sockaddr6;
        socklen_t sockaddr6len = sizeof(sockaddr6);

        if (getpeername(_socket6FD, (struct sockaddr *)&sockaddr6, &sockaddr6len) >= 0 &&
            inet_ntop(AF_INET6, &pSockaddr6->sin6_addr, addrBuf, (socklen_t)sizeof(addrBuf)))
        {
            _connectedPort = ntohs(sockaddr6.sin6_port);
            _connectedHost = [NSString stringWithCString:addrBuf encoding:NSASCIIStringEncoding];
            return;
        }

    }

    _connectedPort = 0;
    _connectedHost = nil;
}

- (bool)connectedToProxy
{
    CHECK_THREAD_SAFETY();

    return _endpointManager.endpoint.type != SPDYOriginEndpointTypeDirect;
}

- (in_port_t)connectedPort
{
    CHECK_THREAD_SAFETY();

    return _connectedPort;
}

- (NSString *)connectedHost
{
    CHECK_THREAD_SAFETY();

    return _connectedHost;
}

- (bool)closed
{
    CHECK_THREAD_SAFETY();
    return _flags & kClosingWithError;
}

- (bool)isIPv4
{
    CHECK_THREAD_SAFETY();

    return (_socket4FD > 0 || _socket4 != NULL);
}

- (bool)isIPv6
{
    CHECK_THREAD_SAFETY();

    return (_socket6FD > 0 || _socket6 != NULL);
}


#pragma mark Reading

- (void)readDataWithTimeout:(NSTimeInterval)timeout tag:(long)tag
{
    [self readDataWithTimeout:timeout buffer:nil bufferOffset:0 maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                        tag:(long)tag
{
    [self readDataWithTimeout:timeout buffer:buffer bufferOffset:offset maxLength:0 tag:tag];
}

- (void)readDataWithTimeout:(NSTimeInterval)timeout
                     buffer:(NSMutableData *)buffer
               bufferOffset:(NSUInteger)offset
                  maxLength:(NSUInteger)length
                        tag:(long)tag
{
    CHECK_THREAD_SAFETY();

    if (offset > buffer.length) return;
    if (_flags & kForbidReadsWrites) return;

    SPDYSocketReadOp *readOp = [[SPDYSocketReadOp alloc] initWithData:buffer
                                                          startOffset:offset
                                                            maxLength:length
                                                              timeout:timeout
                                                          fixedLength:0
                                                                  tag:tag];
    [_readQueue addObject:readOp];
    [self _scheduleRead];
}

- (void)readDataToLength:(NSUInteger)length withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
    [self readDataToLength:length withTimeout:timeout buffer:nil bufferOffset:0 tag:tag];
}

- (void)readDataToLength:(NSUInteger)length
             withTimeout:(NSTimeInterval)timeout
                  buffer:(NSMutableData *)buffer
            bufferOffset:(NSUInteger)offset
                     tag:(long)tag
{
    CHECK_THREAD_SAFETY();

    if (length == 0) return;
    if (offset > buffer.length) return;
    if (_flags & kForbidReadsWrites) return;

    SPDYSocketReadOp *readOp = [[SPDYSocketReadOp alloc] initWithData:buffer
                                                          startOffset:offset
                                                            maxLength:0
                                                              timeout:timeout
                                                          fixedLength:length
                                                                  tag:tag];
    [_readQueue addObject:readOp];
    [self _scheduleRead];
}

- (void)_scheduleRead
{
    if ((_flags & kDequeueReadScheduled) == 0) {
        _flags |= kDequeueReadScheduled;
        [self performSelector:@selector(_dequeueRead) withObject:nil afterDelay:0 inModes:_runLoopModes];
    }
}

- (void)_dequeueRead
{
    _flags &= ~kDequeueReadScheduled;

    if (_readStream && _currentReadOp == nil) {
        if (_readQueue.count > 0) {
            _currentReadOp = [_readQueue objectAtIndex:0];
            [_readQueue removeObjectAtIndex:0];

            if ([_currentReadOp isKindOfClass:[SPDYSocketTLSOp class]]) {
                _flags |= kStartingReadTLS;

                [self _tryTLSHandshake];
            } else {
                if (_currentReadOp->_timeout >= 0.0) {
                    _readTimer = [NSTimer timerWithTimeInterval:_currentReadOp->_timeout
                                                         target:self
                                                       selector:@selector(_timeoutRead:)
                                                       userInfo:nil
                                                        repeats:NO];
                    [self _addTimer:_readTimer];
                }

                [self _read];
            }
        } else if (_flags & kDisconnectAfterReads) {
            if (_flags & kDisconnectAfterWrites) {
                if (_writeQueue.count == 0 && _currentWriteOp == nil) {
                    [self disconnect];
                }
            } else {
                [self disconnect];
            }
        }
    }
}

- (bool)_readStreamReady
{
    return (_flags & kSocketHasBytesAvailable) || CFReadStreamHasBytesAvailable(_readStream);
}

- (void)_read
{
    if (_currentReadOp == nil || _readStream == NULL) {
        return;
    }

    NSError *readError = nil;
    NSUInteger newBytesRead = 0;
    bool readComplete = NO;

    while(!readComplete && !readError && [self _readStreamReady]) {

        NSUInteger bytesToRead = [_currentReadOp safeReadLength];
        NSUInteger bufferSize = _currentReadOp->_buffer.length;
        NSUInteger bufferSpace = bufferSize - _currentReadOp->_startOffset - _currentReadOp->_bytesRead;

        NSAssert(bytesToRead > 0, @"can't read 0 bytes");

        if (bytesToRead > bufferSpace) {
            [_currentReadOp->_buffer increaseLengthBy:(bytesToRead - bufferSpace)];
        }

        uint8_t *readIndex = (uint8_t *)(_currentReadOp->_buffer.mutableBytes +
                                         _currentReadOp->_startOffset         +
                                         _currentReadOp->_bytesRead);

        CFIndex bytesRead = CFReadStreamRead(_readStream, readIndex, bytesToRead);
        _flags &= ~kSocketHasBytesAvailable;

        if (bytesRead < 0) {
            readError = [self streamError];
        } else if (bytesRead == 0) {
            SPDY_INFO(@"socket at end of read stream");
        } else {
            _currentReadOp->_bytesRead += bytesRead;
            newBytesRead += bytesRead;

            if (_currentReadOp->_fixedLength > 0) {
                readComplete = (_currentReadOp->_bytesRead == _currentReadOp->_fixedLength);
            } else if (_currentReadOp->_maxLength > 0) {
                readComplete = (_currentReadOp->_bytesRead >= _currentReadOp->_maxLength);
            }
        }
    }

    if (_currentReadOp->_fixedLength <= 0 && _currentReadOp->_bytesRead > 0) {
        readComplete = YES;
    }

    if ([_currentReadOp isKindOfClass:[SPDYSocketProxyReadOp class]]) {
        // Let's see if the proxy has fully responded
        if (_currentReadOp->_bytesRead > 0) {
            [self _onProxyResponse];
        }
    } else if (readComplete) {
        [self _finishRead];
        if (!readError) [self _scheduleRead];
    } else if (newBytesRead > 0) {
        // Note we will never call this when a proxy connect is happening
        if ([_delegate respondsToSelector:@selector(socket:didReadPartialDataOfLength:tag:)]) {
            [_delegate socket:self didReadPartialDataOfLength:newBytesRead tag:_currentReadOp->_tag];
        }
    }

    if (readError) {
        [self _handleError:readError];
    }
}

- (void)_finishRead
{
    NSAssert(_currentReadOp, @"Trying to complete current read when there is no current read.");

    NSData *readData;

    if (_currentReadOp->_bufferOwner) {
        // We created the buffer so it's safe to trim it
        [_currentReadOp->_buffer setLength:_currentReadOp->_bytesRead];
        readData = _currentReadOp->_buffer;
    } else {
        // The caller owns the buffer, so only trim if we increased its size
        if (_currentReadOp->_buffer.length > _currentReadOp->_originalBufferLength) {
            NSUInteger readLength = _currentReadOp->_startOffset + _currentReadOp->_bytesRead;
            NSUInteger trimmedLength = MAX(readLength, _currentReadOp->_originalBufferLength);
            [_currentReadOp->_buffer setLength:trimmedLength];
        }

        void *buffer = _currentReadOp->_buffer.mutableBytes + _currentReadOp->_startOffset;

        readData = [NSData dataWithBytesNoCopy:buffer length:_currentReadOp->_bytesRead freeWhenDone:NO];
    }

    if ([_delegate respondsToSelector:@selector(socket:didReadData:withTag:)]) {
        [_delegate socket:self didReadData:readData withTag:_currentReadOp->_tag];
    }

    // Caller may have disconnected in the above delegate method
    if (_currentReadOp != nil) {
        [self _endRead];
    }
}

- (void)_endRead
{
    NSAssert(_currentReadOp, @"Trying to end current read when there is no current read.");

    [_readTimer invalidate];
    _readTimer = nil;

    _currentReadOp = nil;
}

- (void)_timeoutRead:(NSTimer *)timer
{
#pragma unused(timer)

    NSTimeInterval timeoutExtension = 0.0;

    if (!(_flags & kConnectingToProxy) &&
            [_delegate respondsToSelector:@selector(socket:willTimeoutReadWithTag:elapsed:bytesDone:)]) {
        timeoutExtension = [_delegate socket:self willTimeoutReadWithTag:_currentReadOp->_tag
                                     elapsed:_currentReadOp->_timeout
                                   bytesDone:_currentReadOp->_bytesRead];
    }

    if (timeoutExtension > 0.0) {
        _currentReadOp->_timeout += timeoutExtension;

        _readTimer = [NSTimer timerWithTimeInterval:timeoutExtension
                                               target:self
                                             selector:@selector(_timeoutRead:)
                                             userInfo:nil
                                              repeats:NO];
        [self _addTimer:_readTimer];
    } else {
        // Do not call _endRead here.
        // We must allow the delegate access to any partial read in the unreadData method.

        [self _closeWithError:[self readTimeoutError]];
    }
}


#pragma mark Writing

- (void)writeData:(NSData *)data withTimeout:(NSTimeInterval)timeout tag:(long)tag
{
    CHECK_THREAD_SAFETY();

    if (data == nil || data.length == 0) return;
    if (_flags & kForbidReadsWrites) return;

    SPDYSocketWriteOp *writeOp = [[SPDYSocketWriteOp alloc] initWithData:data timeout:timeout tag:tag];

    [_writeQueue addObject:writeOp];
    [self _scheduleWrite];

}

- (void)_scheduleWrite
{
    if ((_flags & kDequeueWriteScheduled) == 0) {
        _flags |= kDequeueWriteScheduled;
        [self performSelector:@selector(_dequeueWrite) withObject:nil afterDelay:0 inModes:_runLoopModes];
    }
}

- (void)_dequeueWrite
{
    _flags &= ~kDequeueWriteScheduled;

    if (_writeStream && _currentWriteOp == nil) {
        if (_writeQueue.count > 0) {
            _currentWriteOp = [_writeQueue objectAtIndex:0];
            [_writeQueue removeObjectAtIndex:0];

            if ([_currentWriteOp isKindOfClass:[SPDYSocketTLSOp class]]) {
                _flags |= kStartingWriteTLS;

                [self _tryTLSHandshake];
            } else {
                if (_currentWriteOp->_timeout >= 0.0) {
                    _writeTimer = [NSTimer timerWithTimeInterval:_currentWriteOp->_timeout
                                                            target:self
                                                          selector:@selector(_timeoutWrite:)
                                                          userInfo:nil
                                                           repeats:NO];
                    [self _addTimer:_writeTimer];
                }

                [self _write];
            }
        } else if (_flags & kDisconnectAfterWrites) {
            if (_flags & kDisconnectAfterReads) {
                if (_readQueue.count == 0 && _currentReadOp == nil) {
                    [self disconnect];
                }
            } else {
                [self disconnect];
            }
        }
    }
}

- (bool)_writeStreamReady
{
    return (_flags & kSocketCanAcceptBytes) || CFWriteStreamCanAcceptBytes(_writeStream);
}

- (void)_write
{
    if (_currentWriteOp == nil || _writeStream == NULL) {
        return;
    }

    NSUInteger newBytesWritten = 0;
    bool writeComplete = NO;

    while (!(writeComplete = (_currentWriteOp->_buffer.length == _currentWriteOp->_bytesWritten))&&
            [self _writeStreamReady]) {

        NSUInteger bytesRemaining = _currentWriteOp->_buffer.length - _currentWriteOp->_bytesWritten;
        NSUInteger bytesToWrite = (bytesRemaining < WRITE_CHUNK_SIZE) ? bytesRemaining : WRITE_CHUNK_SIZE;
        uint8_t *writeIndex = (uint8_t *)(_currentWriteOp->_buffer.bytes + _currentWriteOp->_bytesWritten);

        NSAssert(bytesToWrite > 0, @"can't write 0 bytes");

        CFIndex bytesWritten = CFWriteStreamWrite(_writeStream, writeIndex, bytesToWrite);
        _flags &= ~kSocketCanAcceptBytes;

        if (bytesWritten < 0) {
            [self _handleError:[self streamError]];
            return;
        } else if (bytesWritten == 0) {
            SPDY_INFO(@"socket at end of write stream");
        } else {
            _currentWriteOp->_bytesWritten += bytesWritten;
            newBytesWritten += bytesWritten;
        }
    }

    if ([_currentWriteOp isKindOfClass:[SPDYSocketProxyWriteOp class]]) {
        // Proxy connect has been written. We need to block other writes until the read is
        // finished, so we're just going to sit on this op. It will be cleared in _onProxyResponse.
    } else if (writeComplete) {
        [self _finishWrite];
        [self _scheduleWrite];
    } else if (newBytesWritten > 0) {
        // Note we will never call this when a proxy connect is happening
        if ([_delegate respondsToSelector:@selector(socket:didWritePartialDataOfLength:tag:)]) {
            [_delegate socket:self didWritePartialDataOfLength:newBytesWritten tag:_currentWriteOp->_tag];
        }
    }
}

- (void)_finishWrite
{
    NSAssert(_currentWriteOp, @"Trying to complete current write when there is no current write.");

    if (!(_flags & kConnectingToProxy) &&
            [_delegate respondsToSelector:@selector(socket:didWriteDataWithTag:)]) {
        [_delegate socket:self didWriteDataWithTag:_currentWriteOp->_tag];
    }

    if (_currentWriteOp != nil) [self _endWrite]; // caller may have disconnected
}

- (void)_endWrite
{
    NSAssert(_currentWriteOp, @"Trying to complete current write when there is no current write.");

    [_writeTimer invalidate];
    _writeTimer = nil;

    _currentWriteOp = nil;
}

- (void)_timeoutWrite:(NSTimer *)timer
{
#pragma unused(timer)

    NSTimeInterval timeoutExtension = 0.0;

    if (!(_flags & kConnectingToProxy) &&
            [_delegate respondsToSelector:@selector(socket:willTimeoutWriteWithTag:elapsed:bytesDone:)]) {
        timeoutExtension = [_delegate socket:self willTimeoutWriteWithTag:_currentWriteOp->_tag
                                     elapsed:_currentWriteOp->_timeout
                                   bytesDone:_currentWriteOp->_bytesWritten];
    }

    if (timeoutExtension > 0.0) {
        _currentWriteOp->_timeout += timeoutExtension;

        _writeTimer = [NSTimer timerWithTimeInterval:timeoutExtension
                                              target:self
                                            selector:@selector(_timeoutWrite:)
                                            userInfo:nil
                                             repeats:NO];
        [self _addTimer:_writeTimer];
    } else {
        [self _closeWithError:[self writeTimeoutError]];
    }
}


#pragma mark TLS

- (void)secureWithTLS:(NSDictionary *)tlsSettings
{
    CHECK_THREAD_SAFETY();

    // apparently, using nil settings will prevent us from later being able to
    // obtain the remote host's certificate via CFReadStreamCopyProperty(...)
    SPDYSocketTLSOp *tlsOp = [[SPDYSocketTLSOp alloc] initWithTLSSettings:tlsSettings ?: @{}];

    [_readQueue addObject:tlsOp];
    [self _scheduleRead];

    [_writeQueue addObject:tlsOp];
    [self _scheduleWrite];

}

/**
  Starts TLS handshake only if all reads and writes queued prior to the call to
  secureWithTLS: are complete.
*/
- (void)_tryTLSHandshake
{
    NSAssert(!(_flags & kConnectingToProxy), @"no support for TLS to proxy");
    if ((_flags & kStartingReadTLS) && (_flags & kStartingWriteTLS)) {
        SPDYSocketTLSOp *tlsOp = (SPDYSocketTLSOp *)_currentReadOp;

        // If we're using a proxy server, and we're not establishing a TLS connection with the
        // proxy itself, then we need to set the peer name to be the origin host, not the proxy
        // host. Only do this if the app hasn't already set the peer name.
        if (_endpointManager.endpoint.type != SPDYOriginEndpointTypeDirect &&
                !(_flags & kConnectingToProxy) &&
                !tlsOp->_tlsSettings[(__bridge NSString *)kCFStreamSSLPeerName]) {
            NSMutableDictionary *newTlsSettings = [tlsOp->_tlsSettings mutableCopy];
            newTlsSettings[(__bridge NSString *)kCFStreamSSLPeerName] = _endpointManager.endpoint.origin.host;
            tlsOp->_tlsSettings = newTlsSettings;
        }

        bool didStartOnReadStream = CFReadStreamSetProperty(_readStream, kCFStreamPropertySSLSettings,
            (__bridge CFDictionaryRef)tlsOp->_tlsSettings);
        bool didStartOnWriteStream = CFWriteStreamSetProperty(_writeStream, kCFStreamPropertySSLSettings,
            (__bridge CFDictionaryRef)tlsOp->_tlsSettings);

        if (!didStartOnReadStream || !didStartOnWriteStream) {
            [self _closeWithError:SPDY_SOCKET_ERROR(SPDYSocketCFSocketError, @"Error setting stream SSL settings")];
        }
    }
}

- (void)_onTLSHandshakeSuccess
{
    if ((_flags & kStartingReadTLS) && (_flags & kStartingWriteTLS)) {
        _flags &= ~kStartingReadTLS;
        _flags &= ~kStartingWriteTLS;

        bool acceptTrust = YES;
        if ([_delegate respondsToSelector:@selector(socket:securedWithTrust:)]) {
            SecTrustRef trust = (SecTrustRef)CFReadStreamCopyProperty(_readStream, kCFStreamPropertySSLPeerTrust);
            // TODO: Need something to distinguish proxy from endpoint? Only when/if we secure
            // the proxy connection itself with TLS. Not doing that yet.
            acceptTrust = [_delegate socket:self securedWithTrust:trust];
            if (trust) {
                CFRelease(trust);
            }
        }

        if (!acceptTrust) {
            [self _closeWithError:SPDY_SOCKET_ERROR(SPDYSocketTLSVerificationFailed, @"TLS trust verification failed.")];
            return;
        }

        [self _endRead];
        [self _endWrite];

        [self _scheduleRead];
        [self _scheduleWrite];
    }
}

- (void)_onProxyResponse
{
    SPDYSocketProxyReadOp *proxyReadOp = (SPDYSocketProxyReadOp *)_currentReadOp;
    SPDY_DEBUG(@"parsing proxy response: %@", proxyReadOp);
    if ([proxyReadOp tryParseResponse]) {
        if ([proxyReadOp success]) {
            // The write op has clearly completed, since we're received the response, but it's
            // still sitting as the current op. Finish it too.
            //NSAssert([_currentReadOp isKindOfClass:[SPDYSocketProxyReadOp class]], nil);
            //NSAssert([_currentWriteOp isKindOfClass:[SPDYSocketProxyWriteOp class]], nil);

            // Since this is a TCP stream, it's possible for there to be data present after the
            // proxy's HTTP response. However, because we always block on completion of both the
            // proxy read op and proxy write op before executing any additional operations, we
            // won't have sent data. Thus we can't receive data from the origin yet. To do so would
            // be a protocol error.
            // Note that we are allowed to immediately send data to the origin after sending the
            // proxy CONNECT message per the spec, but we don't. In addition, because we should
            // always use TLS with SPDY to the origin, we're doubly safe from an early send and
            // extra receive.
            if (proxyReadOp->_bytesParsed != proxyReadOp->_bytesRead) {
                SPDY_ERROR(@"socket failed proxy connection to %@, response too large: %lu parsed, %lu read",
                        _endpointManager.endpoint, (unsigned long)proxyReadOp->_bytesParsed, (unsigned long)proxyReadOp->_bytesRead);
                [self _handleError:SPDY_SOCKET_ERROR(SPDYSocketProxyError, @"Proxy response too large")];
                return;
            }

            // Successfully connected to proxy server, carry on
            SPDY_INFO(@"socket is now connected to proxy");
            _flags &= ~kConnectingToProxy;

            [self _endConnectTimeout];

            if ([_delegate respondsToSelector:@selector(socket:didConnectToHost:port:)]) {
                [_delegate socket:self didConnectToHost:_connectedHost port:_connectedPort];
            }

            [self _endRead];
            [self _scheduleRead];

            [self _endWrite];
            [self _scheduleWrite];
        } else if ([proxyReadOp needsAuth]) {
            SPDY_ERROR(@"socket failed proxy connection to %@ (auth required), got \"%@\"", _endpointManager.endpoint, proxyReadOp);
            _endpointManager.authRequired = YES;
            [self _handleError:SPDY_SOCKET_ERROR(SPDYSocketProxyError, @"Authentication required (not supported)")];
        } else {
            SPDY_ERROR(@"socket failed proxy connection to %@, got \"%@\"", _endpointManager.endpoint, proxyReadOp);
            [self _handleError:SPDY_SOCKET_ERROR(SPDYSocketProxyError, @"Invalid proxy response")];
        }
    }
}

#pragma mark CFReadStream callbacks

- (void)handleCFReadStreamEvent:(CFStreamEventType)type forStream:(CFReadStreamRef)stream
{
#pragma unused(stream)

    NSParameterAssert(_readStream != NULL);

    switch (type) {
        case kCFStreamEventOpenCompleted:
            _flags |= kDidCompleteOpenForRead;
            [self _onStreamOpened];
            break;
        case kCFStreamEventHasBytesAvailable:
            if (_flags & kStartingReadTLS) {
                [self _onTLSHandshakeSuccess];
            } else {
                _flags |= kSocketHasBytesAvailable;
                [self _read];
            }
            break;
        case kCFStreamEventErrorOccurred:
            [self _handleError:[self streamError]];
            break;
        case kCFStreamEventEndEncountered:
            [self _handleError:SPDY_SOCKET_ERROR(SPDYSocketTransportError, @"Unexpected end of stream.")];
            break;
        default:
            SPDY_WARNING(@"%@ received unexpected CFReadStream callback, CFStreamEventType %li", self, type);
    }
}

- (void)handleCFWriteStreamEvent:(CFStreamEventType)type forStream:(CFWriteStreamRef)stream
{
#pragma unused(stream)

    NSParameterAssert(_writeStream != NULL);

    switch (type) {
        case kCFStreamEventOpenCompleted:
            _flags |= kDidCompleteOpenForWrite;
            [self _onStreamOpened];
            break;
        case kCFStreamEventCanAcceptBytes:
            if (_flags & kStartingWriteTLS) {
                [self _onTLSHandshakeSuccess];
            } else {
                _flags |= kSocketCanAcceptBytes;
                [self _write];
            }
            break;
        case kCFStreamEventErrorOccurred:
        case kCFStreamEventEndEncountered:
            [self _handleError:[self streamError]];
            break;
        default:
            SPDY_WARNING(@"%@ received unexpected CFWriteStream callback, CFStreamEventType %li", self, type);
    }
}

static void SPDYSocketCFReadStreamCallback(CFReadStreamRef stream, CFStreamEventType type, void *pSocket)
{
    @autoreleasepool {
        SPDYSocket * volatile spdySocket = (__bridge SPDYSocket *)pSocket;
        [spdySocket handleCFReadStreamEvent:type forStream:stream];
    }
}

static void SPDYSocketCFWriteStreamCallback(CFWriteStreamRef stream, CFStreamEventType type, void *pSocket)
{
    @autoreleasepool {
        SPDYSocket * volatile spdySocket = (__bridge SPDYSocket *)pSocket;
        [spdySocket handleCFWriteStreamEvent:type forStream:stream];
    }
}

@end
