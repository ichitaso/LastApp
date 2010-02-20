/**
 * Name: LastApp
 * Type: iPhone OS SpringBoard extension (MobileSubstrate-based)
 * Description: Quickly switch to the previously-active application
 * Author: Lance Fetters (aka. ashikase)
 * Last-modified: 2010-02-20 23:15:59
 */

/**
 * Copyright (C) 2010  Lance Fetters (aka. ashikase)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. The name of the author may not be used to endorse or promote
 *    products derived from this software without specific prior
 *    written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */


#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBApplicationController.h>
#import <SpringBoard/SBAwayController.h>
#import <SpringBoard/SBIconController.h>
#import <SpringBoard/SBDisplay.h>
#import <SpringBoard/SBDisplayStack.h>
#import <SpringBoard/SBPowerDownController.h>
#import <SpringBoard/SpringBoard.h>

#import <libactivator/libactivator.h>
 
// NOTE: This is needed to prevent a compiler warning
@interface SpringBoard (Backgrounder)
- (void)setBackgroundingEnabled:(BOOL)enabled forDisplayIdentifier:(NSString *)identifier;
@end

@interface SpringBoard (LastApp)
- (void)switchToLastApp;
@end

//==============================================================================

@interface LastAppActivator : NSObject <LAListener>
{
}
@end

@implementation LastAppActivator
 
+ (void)load
{
    static LastAppActivator *listener = nil;
    if (listener == nil) {
        // Create LastApp's event listener and register it with libactivator
        listener = [[LastAppActivator alloc] init];
	    [[LAActivator sharedInstance] registerListener:listener forName:@APP_ID];
    }
}
 
- (void)activator:(LAActivator *)activator receiveEvent:(LAEvent *)event
{
    SpringBoard *springBoard = (SpringBoard *)[UIApplication sharedApplication];
    [springBoard switchToLastApp];
 
    // Prevent the default OS implementation
	event.handled = YES;
}
 
@end

//==============================================================================

NSMutableArray *displayStacks = nil;

// Display stack names
#define SBWPreActivateDisplayStack        [displayStacks objectAtIndex:0]
#define SBWActiveDisplayStack             [displayStacks objectAtIndex:1]
#define SBWSuspendingDisplayStack         [displayStacks objectAtIndex:2]
#define SBWSuspendedEventOnlyDisplayStack [displayStacks objectAtIndex:3]

%hook SBDisplayStack

- (id)init
{
    id stack = %orig;
    [displayStacks addObject:stack];
    return stack;
}

- (void)dealloc
{
    [displayStacks removeObject:self];
    %orig;
}

%end

//==============================================================================

static BOOL shouldBackground = NO;

static NSString *currentDisplayId = nil;
static NSString *prevDisplayId = nil;

static BOOL canInvoke()
{
    // Should not invoke if either lock screen or power-off screen is active
    SBAwayController *awayCont = [objc_getClass("SBAwayController") sharedAwayController];
    return !([awayCont isLocked]
            || [awayCont isMakingEmergencyCall]
            || [[objc_getClass("SBIconController") sharedInstance] isEditing]
            || [[objc_getClass("SBPowerDownController") sharedInstance] isOrderedFront]);
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(UIApplication *)application
{
    // NOTE: SpringBoard creates four stacks at startup
    // NOTE: Must create array before calling original implementation
    displayStacks = [[NSMutableArray alloc] initWithCapacity:4];

    %orig;
}

- (void)dealloc
{
    [prevDisplayId release];
    [currentDisplayId release];
    [displayStacks release];
    %orig;
}

- (void)frontDisplayDidChange
{
    %orig;

    if ([[objc_getClass("SBAwayController") sharedAwayController] isLocked]
            || [[objc_getClass("SBPowerDownController") sharedInstance] isOrderedFront])
            // Ignore lock screen and power-down screen
            return;

    NSString *displayId = [[SBWActiveDisplayStack topApplication] displayIdentifier];
    if (displayId && ![displayId isEqualToString:currentDisplayId]) {
        // Active application has changed
        // NOTE: SpringBoard is purposely ignored
        // Store the previously-current app as the previous app
        [prevDisplayId autorelease];
        prevDisplayId = currentDisplayId;

        // Store the new current app
        currentDisplayId = [displayId copy];
    }
}

%new(v@:@)
- (void)switchToLastApp
{
    if (!canInvoke())
        return;

    SBApplication *fromApp = [SBWActiveDisplayStack topApplication];
    NSString *fromIdent = [fromApp displayIdentifier];
    if (![fromIdent isEqualToString:prevDisplayId]) {
        // App to switch to is not the current app
        SBApplication *toApp = [[objc_getClass("SBApplicationController") sharedInstance]
            applicationWithDisplayIdentifier:(fromIdent ? prevDisplayId : currentDisplayId)];
        if (toApp) {
            [toApp setDisplaySetting:0x4 flag:YES]; // animate

            if (fromIdent == nil) {
                // Switching from SpringBoard; activate last "current" app
                [SBWPreActivateDisplayStack pushDisplay:toApp];
            } else {
                // Switching from another app; activate previously-active app
                [toApp setActivationSetting:0x40 flag:YES]; // animateOthersSuspension
                [toApp setActivationSetting:0x20000 flag:YES]; // appToApp

                if (shouldBackground)
                    // If Backgrounder is installed, enable backgrounding for current application
                    if ([self respondsToSelector:@selector(setBackgroundingEnabled:forDisplayIdentifier:)])
                        [self setBackgroundingEnabled:YES forDisplayIdentifier:fromIdent];

                // NOTE: Must set animation flag for deactivation, otherwise
                //       application window does not disappear (reason yet unknown)
                [fromApp setDeactivationSetting:0x2 flag:YES]; // animate

                // Activate the target application
                // NOTE: will wait for deactivation of current app due to appToApp flag
                [SBWPreActivateDisplayStack pushDisplay:toApp];

                // Deactivate current application by moving from active to suspending stack
                [SBWActiveDisplayStack popDisplay:fromApp];
                [SBWSuspendingDisplayStack pushDisplay:fromApp];
            }
        }
    }
}

%end

//==============================================================================

static void loadPreferences()
{
    shouldBackground = (BOOL)CFPreferencesGetAppBooleanValue(CFSTR("shouldBackground"), CFSTR(APP_ID), NULL);
}

static void reloadPreferences(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    // NOTE: Must synchronize preferences from disk
    CFPreferencesAppSynchronize(CFSTR(APP_ID));
    loadPreferences();
}

__attribute__((constructor)) static void init()
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    // NOTE: This library should only be loaded for SpringBoard
    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
    if (![identifier isEqualToString:@"com.apple.springboard"])
        return;

    // Initialize hooks
    %init;

    // Load preferences
    loadPreferences();

    // Add observer for changes made to preferences
    CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, reloadPreferences, CFSTR(APP_ID"-settings"),
            NULL, 0);

    // Create the libactivator event listener
    [LastAppActivator load];

    [pool release];
}

/* vim: set syntax=objcpp sw=4 ts=4 sts=4 expandtab textwidth=80 ff=unix: */