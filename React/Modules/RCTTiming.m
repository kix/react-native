/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTTiming.h"

#import "RCTAssert.h"
#import "RCTBridge.h"
#import "RCTLog.h"
#import "RCTSparseArray.h"
#import "RCTUtils.h"

@interface RCTBridge (Private)

/**
 * Allow super fast, one time, timers to skip the queue and be directly executed
 */
- (void)_immediatelyCallTimer:(NSNumber *)timer;

@end

@interface RCTTimer : NSObject

@property (nonatomic, strong, readonly) NSDate *target;
@property (nonatomic, assign, readonly) BOOL repeats;
@property (nonatomic, copy, readonly) NSNumber *callbackID;
@property (nonatomic, assign, readonly) NSTimeInterval interval;

@end

@implementation RCTTimer

- (instancetype)initWithCallbackID:(NSNumber *)callbackID
                          interval:(NSTimeInterval)interval
                        targetTime:(NSTimeInterval)targetTime
                           repeats:(BOOL)repeats
{
  if ((self = [super init])) {
    _interval = interval;
    _repeats = repeats;
    _callbackID = callbackID;
    _target = [NSDate dateWithTimeIntervalSinceNow:targetTime];
  }
  return self;
}

/**
 * Returns `YES` if we should invoke the JS callback.
 */
- (BOOL)updateFoundNeedsJSUpdate
{
  if (_target && _target.timeIntervalSinceNow <= 0) {
    // The JS Timers will do fine grained calculating of expired timeouts.
    _target = _repeats ? [NSDate dateWithTimeIntervalSinceNow:_interval] : nil;
    return YES;
  }
  return NO;
}

@end

@implementation RCTTiming
{
  RCTSparseArray *_timers;
}

@synthesize bridge = _bridge;

RCT_EXPORT_MODULE()

RCT_IMPORT_METHOD(RCTJSTimers, callTimers)

- (instancetype)init
{
  if ((self = [super init])) {

    _timers = [[RCTSparseArray alloc] init];

    for (NSString *name in @[UIApplicationWillResignActiveNotification,
                             UIApplicationDidEnterBackgroundNotification,
                             UIApplicationWillTerminateNotification]) {

      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(stopTimers)
                                                   name:name
                                                 object:nil];
    }

    for (NSString *name in @[UIApplicationDidBecomeActiveNotification,
                             UIApplicationWillEnterForegroundNotification]) {

      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(startTimers)
                                                   name:name
                                                 object:nil];
    }
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (dispatch_queue_t)methodQueue
{
  return RCTJSThread;
}

- (BOOL)isValid
{
  return _bridge != nil;
}

- (void)invalidate
{
  [self stopTimers];
  _bridge = nil;
}

- (void)stopTimers
{
  [_bridge removeFrameUpdateObserver:self];
}

- (void)startTimers
{
  if (![self isValid] || _timers.count == 0) {
    return;
  }

  [_bridge addFrameUpdateObserver:self];
}

- (void)didUpdateFrame:(RCTFrameUpdate *)update
{
  NSMutableArray *timersToCall = [[NSMutableArray alloc] init];
  for (RCTTimer *timer in _timers.allObjects) {
    if ([timer updateFoundNeedsJSUpdate]) {
      [timersToCall addObject:timer.callbackID];
    }
    if (!timer.target) {
      _timers[timer.callbackID] = nil;
    }
  }

  // call timers that need to be called
  if ([timersToCall count] > 0) {
    [_bridge enqueueJSCall:@"RCTJSTimers.callTimers" args:@[timersToCall]];
  }
}

/**
 * There's a small difference between the time when we call
 * setTimeout/setInterval/requestAnimation frame and the time it actually makes
 * it here. This is important and needs to be taken into account when
 * calculating the timer's target time. We calculate this by passing in
 * Date.now() from JS and then subtracting that from the current time here.
 */
RCT_EXPORT_METHOD(createTimer:(NSNumber *)callbackID
                  duration:(NSTimeInterval)jsDuration
                  jsSchedulingTime:(NSDate *)jsSchedulingTime
                  repeats:(BOOL)repeats)
{
  if (jsDuration == 0 && repeats == NO) {
    // For super fast, one-off timers, just enqueue them immediately rather than waiting a frame.
    [_bridge _immediatelyCallTimer:callbackID];
    return;
  }

  NSTimeInterval jsSchedulingOverhead = -jsSchedulingTime.timeIntervalSinceNow;
  if (jsSchedulingOverhead < 0) {
    RCTLogWarn(@"jsSchedulingOverhead (%ims) should be positive", (int)(jsSchedulingOverhead * 1000));
  }

  NSTimeInterval targetTime = jsDuration - jsSchedulingOverhead;
  if (jsDuration < 0.018) { // Make sure short intervals run each frame
    jsDuration = 0;
  }

  RCTTimer *timer = [[RCTTimer alloc] initWithCallbackID:callbackID
                                                interval:jsDuration
                                              targetTime:targetTime
                                                 repeats:repeats];
  _timers[callbackID] = timer;
  [self startTimers];
}

RCT_EXPORT_METHOD(deleteTimer:(NSNumber *)timerID)
{
  if (timerID) {
    _timers[timerID] = nil;
    if (_timers.count == 0) {
      [self stopTimers];
    }
  } else {
    RCTLogWarn(@"Called deleteTimer: with a nil timerID");
  }
}

@end
