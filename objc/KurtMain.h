/*!
 @file KurtMain.h
 @discussion Core of the Kurt web server.
 @copyright Copyright (c) 2010 Neon Design Technology, Inc.
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import <Foundation/Foundation.h>
#import <Nu/Nu.h>

@class KurtRequest;

@protocol KurtDelegate <NSObject>
// Override this to perform Objective-C setup of your Kurt.
- (void) applicationDidFinishLaunching;

// Load a Nu source file containing a site description and chdir to the containing directory.
- (void) configureSite:(NSString *) site;

// Call this within applicationDidFinishLaunching to add a handler.
// The block argument can be a Nu or Objective-C block.
- (void) addHandlerWithHTTPMethod:(NSString *)httpMethod path:(NSString *)path block:(id)block;

// Call this within applicationDidFinishLaunching to set the 404 handler.
- (void) setDefaultHandlerWithBlock:(id) block;

// Handle a request. You probably won't need this if you use the KurtDefaultDelegate.
- (void) handleRequest:(KurtRequest *)request;

// Dump a description of the service
- (void) dump;
@end


@interface Kurt : NSObject {}
// Get a Kurt instance. We only support one per process.
+ (Kurt *) kurt;

// Control logging
+ (void) setVerbose:(BOOL) v;
+ (BOOL) verbose;

// Known MIME types
+ (NSMutableDictionary *) mimeTypes;
+ (void) setMimeTypes:(NSMutableDictionary *) dictionary;
+ (NSString *) mimeTypeForFileWithName:(NSString *) filename;

// The delegate performs all request handling.
- (void) setDelegate:(id<KurtDelegate>) d;
- (id<KurtDelegate>) delegate;

// Bind the server to a specified address and port.
- (int) bindToAddress:(NSString *) address port:(int) port;

// Run the server.
- (void) run;

@end


// Run Kurt. Pass nil for KurtDelegateClassName to use the default delegate.
// If it exists, a file named "site.nu" will be read and run to configure the delegate.
int KurtMain(int argc, const char *argv[], NSString *KurtDelegateClassName);
