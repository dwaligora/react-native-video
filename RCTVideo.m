#import "RCTConvert.h"
#import "RCTVideo.h"
#import "RCTBridgeModule.h"
#import "RCTEventDispatcher.h"
#import "UIView+React.h"

static NSString *const statusKeyPath = @"status";
static NSString *const playbackLikelyToKeepUpKeyPath = @"playbackLikelyToKeepUp";
static NSString *const playbackBufferEmptyKeyPath = @"playbackBufferEmpty";
static NSString *const readyForDisplayKeyPath = @"readyForDisplay";
static NSString *const playbackRate = @"rate";

@implementation RCTVideo
{
  AVPlayer *_player;
  AVPlayerItem *_playerItem;
  BOOL _playerItemObserversSet;
  BOOL _playerBufferEmpty;
  AVPlayerLayer *_playerLayer;
  AVPlayerViewController *_playerViewController;
  NSURL *_videoURL;

  /* Required to publish events */
  RCTEventDispatcher *_eventDispatcher;

  bool _pendingSeek;
  float _pendingSeekTime;
  float _lastSeekTime;

  /* For sending videoProgress events */
  Float64 _progressUpdateInterval;
  BOOL _controls;
  id _timeObserver;

  /* Keep track of any modifiers, need to be applied after each play */
  float _volume;
  float _rate;
  BOOL _muted;
  BOOL _paused;
  BOOL _repeat;
  BOOL _playbackStalled;
  NSString * _resizeMode;
  BOOL _fullscreenPlayerPresented;
  UIViewController * _presentingViewController;
}

- (instancetype)initWithEventDispatcher:(RCTEventDispatcher *)eventDispatcher
{
  if ((self = [super init])) {
    _eventDispatcher = eventDispatcher;

    _playbackStalled = NO;
    _rate = 1.0;
    _volume = 1.0;
    _resizeMode = @"AVLayerVideoGravityResizeAspectFill";
    _pendingSeek = false;
    _pendingSeekTime = 0.0f;
    _lastSeekTime = 0.0f;
    _progressUpdateInterval = 250;
    _controls = NO;
    _playerBufferEmpty = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
  }

  return self;
}

- (AVPlayerViewController*)createPlayerViewController:(AVPlayer*)player withPlayerItem:(AVPlayerItem*)playerItem {
    RCTVideoPlayerViewController* playerLayer= [[RCTVideoPlayerViewController alloc] init];
    playerLayer.showsPlaybackControls = YES;
    playerLayer.rctDelegate = self;
    playerLayer.view.frame = self.bounds;
    playerLayer.player = _player;
    playerLayer.view.frame = self.bounds;
    return playerLayer;
}

/* ---------------------------------------------------------
 **  Get the duration for a AVPlayerItem.
 ** ------------------------------------------------------- */

- (CMTime)playerItemDuration
{
    AVPlayerItem *playerItem = [_player currentItem];
    if (playerItem.status == AVPlayerItemStatusReadyToPlay)
    {
        return([playerItem duration]);
    }
    
    return(kCMTimeInvalid);
}


/* Cancels the previously registered time observer. */
-(void)removePlayerTimeObserver
{
    if (_timeObserver)
    {
        [_player removeTimeObserver:_timeObserver];
        _timeObserver = nil;
    }
}

#pragma mark - Progress

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - App lifecycle handlers

- (void)applicationWillResignActive:(NSNotification *)notification
{
  if (!_paused) {
    [_player pause];
    [_player setRate:0.0];
  }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
  [self applyModifiers];
}

#pragma mark - Progress

- (void)sendProgressUpdate
{
   AVPlayerItem *video = [_player currentItem];
   if (video == nil || video.status != AVPlayerItemStatusReadyToPlay) {
     return;
   }
    
   CMTime playerDuration = [self playerItemDuration];
   if (CMTIME_IS_INVALID(playerDuration)) {
      return;
   }

   CMTime currentTime = _player.currentTime;
   const Float64 duration = CMTimeGetSeconds(playerDuration);
   const Float64 currentTimeSecs = CMTimeGetSeconds(currentTime);
   if( currentTimeSecs >= 0 && currentTimeSecs <= duration) {
        [_eventDispatcher sendInputEventWithName:@"onVideoProgress"
                                            body:@{
                                                     @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)],
                                                     @"playableDuration": [self calculatePlayableDuration],
                                                     @"atValue": [NSNumber numberWithLongLong:currentTime.value],
                                                     @"atTimescale": [NSNumber numberWithInt:currentTime.timescale],
                                                     @"target": self.reactTag
                                                 }];
   }
}

/*!
 * Calculates and returns the playable duration of the current player item using its loaded time ranges.
 *
 * \returns The playable duration of the current player item in seconds.
 */
- (NSNumber *)calculatePlayableDuration
{
  AVPlayerItem *video = _player.currentItem;
  if (video.status == AVPlayerItemStatusReadyToPlay) {
    __block CMTimeRange effectiveTimeRange;
    [video.loadedTimeRanges enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
      CMTimeRange timeRange = [obj CMTimeRangeValue];
      if (CMTimeRangeContainsTime(timeRange, video.currentTime)) {
        effectiveTimeRange = timeRange;
        *stop = YES;
      }
    }];
    Float64 playableDuration = CMTimeGetSeconds(CMTimeRangeGetEnd(effectiveTimeRange));
    if (playableDuration > 0) {
      return [NSNumber numberWithFloat:playableDuration];
    }
  }
  return [NSNumber numberWithInteger:0];
}

- (void)addPlayerItemObservers
{
  [_playerItem addObserver:self forKeyPath:statusKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackBufferEmptyKeyPath options:0 context:nil];
  [_playerItem addObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath options:0 context:nil];
  _playerItemObserversSet = YES;
}

/* Fixes https://github.com/brentvatne/react-native-video/issues/43
 * Crashes caused when trying to remove the observer when there is no
 * observer set */
- (void)removePlayerItemObservers
{
  if (_playerItemObserversSet) {
    [_playerItem removeObserver:self forKeyPath:statusKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackBufferEmptyKeyPath];
    [_playerItem removeObserver:self forKeyPath:playbackLikelyToKeepUpKeyPath];
    _playerItemObserversSet = NO;
  }
}

#pragma mark - Player and source

- (void)setSrc:(NSDictionary *)source
{
  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];
  _playerItem = [self playerItemForSource:source];
  [self addPlayerItemObservers];

  [_player pause];
  [self removePlayerLayer];
  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;

  _player = [AVPlayer playerWithPlayerItem:_playerItem];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  [_player addObserver:self forKeyPath:playbackRate options:0 context:nil];

  const Float64 progressUpdateIntervalMS = _progressUpdateInterval / 1000;
  // @see endScrubbing in AVPlayerDemoPlaybackViewController.m of https://developer.apple.com/library/ios/samplecode/AVPlayerDemo/Introduction/Intro.html
  __weak RCTVideo *weakSelf = self;
  _timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(progressUpdateIntervalMS, NSEC_PER_SEC)
                                                        queue:NULL
                                                   usingBlock:^(CMTime time) { [weakSelf sendProgressUpdate]; }
                   ];
  [_eventDispatcher sendInputEventWithName:@"onVideoLoadStart"
                                      body:@{@"src": @{
                                                 @"uri": [source objectForKey:@"uri"],
                                                 @"type": [source objectForKey:@"type"],
                                                 @"isNetwork":[NSNumber numberWithBool:(bool)[source objectForKey:@"isNetwork"]]},
                                             @"target": self.reactTag}];
}

- (AVPlayerItem*)playerItemForSource:(NSDictionary *)source
{
  bool isNetwork = [RCTConvert BOOL:[source objectForKey:@"isNetwork"]];
  bool isAsset = [RCTConvert BOOL:[source objectForKey:@"isAsset"]];
  NSString *uri = [source objectForKey:@"uri"];
  NSString *type = [source objectForKey:@"type"];

  NSURL *url = (isNetwork || isAsset) ?
    [NSURL URLWithString:uri] :
    [[NSURL alloc] initFileURLWithPath:[[NSBundle mainBundle] pathForResource:uri ofType:type]];

  if (isAsset) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    return [AVPlayerItem playerItemWithAsset:asset];
  }

  return [AVPlayerItem playerItemWithURL:url];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
   if (object == _playerItem) {

    if ([keyPath isEqualToString:statusKeyPath]) {
      // Handle player item status change.
      if (_playerItem.status == AVPlayerItemStatusReadyToPlay) {
        float duration = CMTimeGetSeconds(_playerItem.asset.duration);

        if (isnan(duration)) {
          duration = 0.0;
        }
          
        NSObject *width = @"undefined";
        NSObject *height = @"undefined";
        NSString *orientation = @"undefined";

        if ([_playerItem.asset tracksWithMediaType:AVMediaTypeVideo].count > 0) {
          AVAssetTrack *videoTrack = [[_playerItem.asset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0];
          width = [NSNumber numberWithFloat:videoTrack.naturalSize.width];
          height = [NSNumber numberWithFloat:videoTrack.naturalSize.height];
          CGAffineTransform preferredTransform = [videoTrack preferredTransform];

          if ((videoTrack.naturalSize.width == preferredTransform.tx
            && videoTrack.naturalSize.height == preferredTransform.ty)
            || (preferredTransform.tx == 0 && preferredTransform.ty == 0))
          {
            orientation = @"landscape";
          } else
            orientation = @"portrait";
        }

        [_eventDispatcher sendInputEventWithName:@"onVideoLoad"
                                            body:@{@"duration": [NSNumber numberWithFloat:duration],
                                                   @"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(_playerItem.currentTime)],
                                                   @"canPlayReverse": [NSNumber numberWithBool:_playerItem.canPlayReverse],
                                                   @"canPlayFastForward": [NSNumber numberWithBool:_playerItem.canPlayFastForward],
                                                   @"canPlaySlowForward": [NSNumber numberWithBool:_playerItem.canPlaySlowForward],
                                                   @"canPlaySlowReverse": [NSNumber numberWithBool:_playerItem.canPlaySlowReverse],
                                                   @"canStepBackward": [NSNumber numberWithBool:_playerItem.canStepBackward],
                                                   @"canStepForward": [NSNumber numberWithBool:_playerItem.canStepForward],
                                                   @"naturalSize": @{
                                                        @"width": width,
                                                        @"height": height,
                                                        @"orientation": orientation
                                                        },
                                                   @"target": self.reactTag}];

        [self attachListeners];
        [self applyModifiers];
      } else if(_playerItem.status == AVPlayerItemStatusFailed) {
        [_eventDispatcher sendInputEventWithName:@"onVideoError"
                                            body:@{@"error": @{
                                                       @"code": [NSNumber numberWithInteger: _playerItem.error.code],
                                                       @"domain": _playerItem.error.domain},
                                                   @"target": self.reactTag}];
      }
    } else if ([keyPath isEqualToString:playbackBufferEmptyKeyPath]) {
      _playerBufferEmpty = YES;
    } else if ([keyPath isEqualToString:playbackLikelyToKeepUpKeyPath]) {
      // Continue playing (or not if paused) after being paused due to hitting an unbuffered zone.
      if ((!_controls || _playerBufferEmpty) && _playerItem.playbackLikelyToKeepUp) {
        [self setPaused:_paused];
      }
      _playerBufferEmpty = NO;
    }
   } else if (object == _playerLayer) {
      if([keyPath isEqualToString:readyForDisplayKeyPath] && [change objectForKey:NSKeyValueChangeNewKey]) {
        if([change objectForKey:NSKeyValueChangeNewKey]) {
          [_eventDispatcher sendInputEventWithName:@"onReadyForDisplay"
                                              body:@{@"target": self.reactTag}];
        }
    }
  } else if (object == _player) {
      if([keyPath isEqualToString:playbackRate]) {
          [_eventDispatcher sendInputEventWithName:@"onPlaybackRateChange"
                                              body:@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                                     @"target": self.reactTag}];
          if(_playbackStalled && _player.rate > 0) {
              [_eventDispatcher sendInputEventWithName:@"onPlaybackResume"
                                                  body:@{@"playbackRate": [NSNumber numberWithFloat:_player.rate],
                                                         @"target": self.reactTag}];
              _playbackStalled = NO;
          }
      }
  } else {
      [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

- (void)attachListeners
{
  // listen for end of file
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemDidReachEnd:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:[_player currentItem]];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playbackStalled:)
                                               name:AVPlayerItemPlaybackStalledNotification
                                             object:nil];
}

- (void)playbackStalled:(NSNotification *)notification
{
  [_eventDispatcher sendInputEventWithName:@"onPlaybackStalled" body:@{@"target": self.reactTag}];
  _playbackStalled = YES;
}

- (void)playerItemDidReachEnd:(NSNotification *)notification
{
  [_eventDispatcher sendInputEventWithName:@"onVideoEnd" body:@{@"target": self.reactTag}];

  if (_repeat) {
    AVPlayerItem *item = [notification object];
    [item seekToTime:kCMTimeZero];
    [self applyModifiers];
  }
}

#pragma mark - Prop setters

- (void)setResizeMode:(NSString*)mode
{
  if( _controls )
  {
    _playerViewController.videoGravity = mode;
  }
  else
  {
    _playerLayer.videoGravity = mode;
  }
  _resizeMode = mode;
}

- (void)setPaused:(BOOL)paused
{
  if (paused) {
    [_player pause];
    [_player setRate:0.0];
  } else {
    [_player play];
    [_player setRate:_rate];
  }
  
  _paused = paused;
}

- (float)getCurrentTime
{
  return _playerItem != NULL ? CMTimeGetSeconds(_playerItem.currentTime) : 0;
}

- (void)setCurrentTime:(float)currentTime
{
  [self setSeek: currentTime];
}

- (void)setSeek:(float)seekTime
{
  int timeScale = 10000;

  AVPlayerItem *item = _player.currentItem;
  if (item && item.status == AVPlayerItemStatusReadyToPlay) {
    // TODO check loadedTimeRanges

    CMTime cmSeekTime = CMTimeMakeWithSeconds(seekTime, timeScale);
    CMTime current = item.currentTime;
    // TODO figure out a good tolerance level
    CMTime tolerance = CMTimeMake(1000, timeScale);
    
    if (CMTimeCompare(current, cmSeekTime) != 0) {
      [_player seekToTime:cmSeekTime toleranceBefore:tolerance toleranceAfter:tolerance completionHandler:^(BOOL finished) {
        [_eventDispatcher sendInputEventWithName:@"onVideoSeek"
                                            body:@{@"currentTime": [NSNumber numberWithFloat:CMTimeGetSeconds(item.currentTime)],
                                                   @"seekTime": [NSNumber numberWithFloat:seekTime],
                                                   @"target": self.reactTag}];
      }];

      _pendingSeek = false;
    }

  } else {
    // TODO: See if this makes sense and if so, actually implement it
    _pendingSeek = true;
    _pendingSeekTime = seekTime;
  }
}

- (void)setRate:(float)rate
{
  _rate = rate;
  [self applyModifiers];
}

- (void)setMuted:(BOOL)muted
{
  _muted = muted;
  [self applyModifiers];
}

- (void)setVolume:(float)volume
{
  _volume = volume;
  [self applyModifiers];
}

- (void)applyModifiers
{
  if (_muted) {
    [_player setVolume:0];
    [_player setMuted:YES];
  } else {
    [_player setVolume:_volume];
    [_player setMuted:NO];
  }

  [self setResizeMode:_resizeMode];
  [self setRepeat:_repeat];
  [self setPaused:_paused];
  [self setControls:_controls];
}

- (void)setRepeat:(BOOL)repeat {
  _repeat = repeat;
}

- (BOOL)getFullscreen
{
    return _fullscreenPlayerPresented;
}

- (void)setFullscreen:(BOOL)fullscreen
{
    if( fullscreen && !_fullscreenPlayerPresented )
    {
        // Ensure player view controller is not null
        if( !_playerViewController )
        {
            [self usePlayerViewController];
        }
        // Set presentation style to fullscreen
        [_playerViewController setModalPresentationStyle:UIModalPresentationFullScreen];
        
        // Find the nearest view controller
        UIViewController *viewController = [self firstAvailableUIViewController];
        if( !viewController )
        {
            UIWindow *keyWindow = [[UIApplication sharedApplication] keyWindow];
            viewController = keyWindow.rootViewController;
            if( viewController.childViewControllers.count > 0 )
            {
                viewController = viewController.childViewControllers.lastObject;
            }
        }
        if( viewController )
        {
            _presentingViewController = viewController;
            [_eventDispatcher sendInputEventWithName:@"onVideoFullscreenPlayerWillPresent" body:@{@"target": self.reactTag}];
            [viewController presentViewController:_playerViewController animated:true completion:^{
                _playerViewController.showsPlaybackControls = YES;
                _fullscreenPlayerPresented = fullscreen;
                [_eventDispatcher sendInputEventWithName:@"onVideoFullscreenPlayerDidPresent" body:@{@"target": self.reactTag}];
            }];
        }
    }
    else if ( !fullscreen && _fullscreenPlayerPresented )
    {
        [self videoPlayerViewControllerWillDismiss:_playerViewController];
        [_presentingViewController dismissViewControllerAnimated:true completion:^{
            [self videoPlayerViewControllerDidDismiss:_playerViewController];
        }];
    }
}

- (void)usePlayerViewController
{
    if( _player )
    {
        _playerViewController = [self createPlayerViewController:_player withPlayerItem:_playerItem];
        [self addSubview:_playerViewController.view];
    }
}

- (void)usePlayerLayer
{
    if( _player )
    {
      _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
      _playerLayer.frame = self.bounds;
      _playerLayer.needsDisplayOnBoundsChange = YES;
        
      [_playerLayer addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
    
      [self.layer addSublayer:_playerLayer];
      self.layer.needsDisplayOnBoundsChange = YES;
    }
}

- (void)setControls:(BOOL)controls
{
    if( _controls != controls || (!_playerLayer && !_playerViewController) )
    {
        _controls = controls;
        if( _controls )
        {
            [self removePlayerLayer];
            [self usePlayerViewController];
        }
        else
        {
            [_playerViewController.view removeFromSuperview];
            _playerViewController = nil;
            [self usePlayerLayer];
        }
    }
}

- (void)removePlayerLayer
{
    [_playerLayer removeFromSuperlayer];
    [_playerLayer removeObserver:self forKeyPath:readyForDisplayKeyPath];
    _playerLayer = nil;
}

#pragma mark - RCTVideoPlayerViewControllerDelegate

- (void)videoPlayerViewControllerWillDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented)
    {
        [_eventDispatcher sendInputEventWithName:@"onVideoFullscreenPlayerWillDismiss" body:@{@"target": self.reactTag}];
    }
}

- (void)videoPlayerViewControllerDidDismiss:(AVPlayerViewController *)playerViewController
{
    if (_playerViewController == playerViewController && _fullscreenPlayerPresented)
    {
        _fullscreenPlayerPresented = false;
        _presentingViewController = nil;
        [self applyModifiers];
        [_eventDispatcher sendInputEventWithName:@"onVideoFullscreenPlayerDidDismiss" body:@{@"target": self.reactTag}];
    } else {
        // TODO: not elegant way of triggering the dismiss event but somehow it isnt triggered
        // when user click DONE button
        [_eventDispatcher sendInputEventWithName:@"onVideoFullscreenPlayerDidDismiss" body:@{@"target": self.reactTag, @"dismissed": @YES}];
    }
}

#pragma mark - React View Management

- (void)insertReactSubview:(UIView *)view atIndex:(NSInteger)atIndex
{
  // We are early in the game and somebody wants to set a subview.
  // That can only be in the context of playerViewController.
  if( !_controls && !_playerLayer && !_playerViewController )
  {
    [self setControls:true];
  }
  
  if( _controls )
  {
     view.frame = self.bounds;
     [_playerViewController.contentOverlayView insertSubview:view atIndex:atIndex];
  }
  else
  {
     RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)removeReactSubview:(UIView *)subview
{
  if( _controls )
  {
      [subview removeFromSuperview];
  }
  else
  {
    RCTLogError(@"video cannot have any subviews");
  }
  return;
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if( _controls )
  {
    _playerViewController.view.frame = self.bounds;
  
    // also adjust all subviews of contentOverlayView
    for (UIView* subview in _playerViewController.contentOverlayView.subviews) {
      subview.frame = self.bounds;
    }
  }
  else
  {
      [CATransaction begin];
      [CATransaction setAnimationDuration:0];
      _playerLayer.frame = self.bounds;
      [CATransaction commit];
  }
}

#pragma mark - Lifecycle

- (void)removeFromSuperview
{
  [_player pause];
  [_player removeObserver:self forKeyPath:playbackRate];
  _player = nil;

  [self removePlayerLayer];
  
  [_playerViewController.view removeFromSuperview];
  _playerViewController = nil;

  [self removePlayerTimeObserver];
  [self removePlayerItemObservers];

  _eventDispatcher = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];

  [super removeFromSuperview];
}

@end
