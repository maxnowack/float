#ifndef FLOAT_PIP_PROXY_H
#define FLOAT_PIP_PROXY_H

#import <Cocoa/Cocoa.h>

// Readability-only proxy declarations for private PIP.framework symbols.
// Swift runtime integration still uses dynamic selector checks for compatibility.

@class PIPViewController;

@protocol PIPViewControllerDelegate <NSObject>

@optional
- (void)pipActionStop:(PIPViewController *)pip;
- (void)pipActionPause:(PIPViewController *)pip;
- (void)pipActionPlay:(PIPViewController *)pip;
- (void)pipActionReturn:(PIPViewController *)pip;
- (void)pipDidClose:(PIPViewController *)pip;
- (void)pipWillClose:(PIPViewController *)pip;

@end

@interface PIPViewController : NSViewController

@property (nonatomic, weak) id<PIPViewControllerDelegate> delegate;
@property (nonatomic, assign) NSRect replacementRect;
@property (nonatomic, weak) NSWindow *replacementWindow;
@property (nonatomic, weak) NSView *replacementView;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) NSSize aspectRatio;

- (void)presentViewControllerAsPictureInPicture:(__kindof NSViewController *)controller;
- (void)performWindowDragWithEvent:(id)arg1;
- (void)setPlaying:(BOOL)playing;
- (BOOL)playing;

- (instancetype)init;

@end

#endif  // FLOAT_PIP_PROXY_H
