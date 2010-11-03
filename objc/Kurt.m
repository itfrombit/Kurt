/*!
 @file Kurt.m
 @discussion Core of the Kurt web server.
 @copyright Copyright (c) 2008 Neon Design Technology, Inc.

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

#include <sys/types.h>
#include <sys/time.h>
#include <sys/queue.h>

#include <event2/event.h>
#include <event2/http.h>
#include <event2/event_compat.h>
#include <event2/http_compat.h>
#include <event2/http_struct.h>
#include <event2/buffer.h>
#include <event2/buffer_compat.h>

#include <netdb.h>
#include <arpa/inet.h>                            // inet_ntoa
#include <event2/dns.h>
#include <event2/dns_compat.h>

#include <signal.h>                               // SIGPIPE

#define HTTP_SEEOTHER 303
#define HTTP_DENIED 403

#import <Foundation/Foundation.h>
#import <Nu/Nu.h>

#import "KurtMain.h"
#import "KurtRequest.h"
#import "KurtDelegate.h"

void kurt_response_helper(struct evhttp_request *req, int code, NSString *message, NSData *data);

void KurtInit()
{
    static int initialized = 0;
    if (!initialized) {
        initialized = 1;
        [Nu loadNuFile:@"kurt" fromBundleWithIdentifier:@"nu.programming.kurt" withContext:nil];
    }
}

BOOL verbose_kurt = NO;

@interface ConcreteKurt : Kurt
{
    struct event_base *event_base;
    struct evhttp *httpd;
    id<NSObject,KurtDelegate> delegate;

    NSThread *workerThread;
    struct event *watchdogEvent;
    int watchdogRecvFd;
    int watchdogSendFd;
}

- (id) delegate;
@end

@implementation ConcreteKurt

+ (void) load
{
    KurtInit();
}

static void kurt_request_handler(struct evhttp_request *req, void *kurt_pointer)
{
    Kurt *kurt = (Kurt *) kurt_pointer;
    id delegate = [kurt delegate];
    if (delegate) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        KurtRequest *request = [[KurtRequest alloc] initWithKurt:kurt request:req];
        [delegate handleRequest:request];
        [request release];
        [pool release];
    }
    else {
        kurt_response_helper(req, HTTP_OK, @"OK",
            [[NSString stringWithFormat:@"Please set the Kurt delegate.<br/>If you are running kurtd, use the '-s' option to specify a site.<br/>\nRequest: %s\n",
            evhttp_request_uri(req)]
            dataUsingEncoding:NSUTF8StringEncoding]);
    }
}

- (id) init
{
    [super init];
    event_base = event_init();
    evdns_init();
    httpd = evhttp_new(event_base);
    evhttp_set_gencb(httpd, kurt_request_handler, self);
    delegate = nil;

    workerThread = nil;
    watchdogEvent = NULL;
    watchdogRecvFd = -1;
    watchdogSendFd = -1;

    return self;
}

- (int) bindToAddress:(NSString *) address port:(int) port
{
    return evhttp_bind_socket(httpd, [address cStringUsingEncoding:NSUTF8StringEncoding], port);
}

static void sig_pipe(int signo)
{
    NSLog(@"SIGPIPE: lost connection during write. (signal %d)", signo);
}

struct event_base *gevent_base;

static void sig_int(int sig)
{
    signal(sig, SIG_IGN);
    event_base_loopexit(gevent_base, NULL); // exits libevent loop
}

- (void) run
{
    if (verbose_kurt && ([delegate respondsToSelector:@selector(dump)])) {
        [delegate dump];
    }

    gevent_base = event_base;
    signal(SIGINT, sig_int);

    if (signal(SIGPIPE, sig_pipe) == SIG_ERR) {
        NSLog(@"failed to setup SIGPIPE handler.");
    }
    event_base_dispatch(event_base);
}

static void watchdogCallback(int fd, short what, void *arg)
{
    NSLog(@"Watchdog event received. Stopping Kurt.");
    event_base_loopexit(gevent_base, NULL);
    ConcreteKurt* kurtObject = (ConcreteKurt*)arg;
    [kurtObject performSelectorOnMainThread:@selector(cleanupWorkerThread) withObject:nil waitUntilDone:NO];
}

- (void) start
{
    if (!workerThread) {
        int pipeFds[2];
        if (pipe(pipeFds) != 0)
        {
            NSLog(@"Can't create watchdog pipe. Kurt not started.");
            return;
        }

        watchdogRecvFd = pipeFds[0];
        watchdogSendFd = pipeFds[1];

        watchdogEvent = event_new(gevent_base, watchdogRecvFd, EV_READ, watchdogCallback, (void*)self);
        event_add(watchdogEvent, NULL);

        workerThread = [[NSThread alloc] initWithTarget:self
                                               selector:@selector(run)
                                                 object:nil];
        [workerThread start];
    }
    else {
        NSLog(@"Kurt is already running.");
    }
}

- (void) cleanupWorkerThread
{
    if (workerThread)
    {
        NSLog(@"Cleaning up worker thread.");
        event_del(watchdogEvent);
        event_free(watchdogEvent);
        watchdogEvent = NULL;
        [workerThread release];
        workerThread = nil;
        close(watchdogRecvFd);
        close(watchdogSendFd);
        watchdogRecvFd = -1;
        watchdogSendFd = -1;
    }
}

- (void) stop
{
    if (workerThread) {
        write(watchdogSendFd, "", 1);
    }
    else {
        NSLog(@"Kurt is not running.");
    }
}

- (void) dealloc
{
    evhttp_free(httpd);
    [super dealloc];
}

- (id) delegate
{
    if (!delegate) {
        [self setDelegate:[[[KurtDefaultDelegate alloc] init] autorelease]];
    }
    return delegate;
}

- (void) setDelegate:(id) d
{
    [d retain];
    [delegate release];
    delegate = d;
}

@class NuBlock;
@class NuCell;

static void kurt_dns_gethostbyname_cb(int result, char type, int count, int ttl, void *addresses, void *arg)
{
    id address = nil;
    if (result == DNS_ERR_TIMEOUT) {
        fprintf(stdout, "[Timed out] ");
    }
    else if (result != DNS_ERR_NONE) {
        fprintf(stdout, "[Error code %d] ", result);
    }
    else {
        fprintf(stdout, "type: %d, count: %d, ttl: %d\n", type, count, ttl);
        switch (type) {
            case DNS_IPv4_A:
            {
                struct in_addr *in_addrs = addresses;
                if (ttl < 0) {
                    // invalid resolution
                }
                else if (count == 0) {
                    // no addresses
                }
                else {
                    address = [NSString stringWithFormat:@"%s", inet_ntoa(in_addrs[0])];
                }
                break;
            }
            case DNS_PTR:
                /* may get at most one PTR */
                // this needs review. TB.
                if (count == 1)
                    fprintf(stdout, "addresses: %s ", *(char **)addresses);
                break;
            default:
                break;
        }
    }
    NuBlock *block = (NuBlock *) arg;
    NuCell *args = [[NuCell alloc] init];
    [args setCar:address];
    [block evalWithArguments:args context:nil];
    [block release];
    [args release];
}

- (void) resolveDomainName:(NSString *) name andDo:(NuBlock *) block
{
    [block retain];
    evdns_resolve_ipv4([name cStringUsingEncoding:NSUTF8StringEncoding], 0, kurt_dns_gethostbyname_cb, block);
}

void kurt_http_request_done(struct evhttp_request *req, void *arg)
{
    NSData *data = nil;
    if (req->response_code != HTTP_OK) {
        if (req->response_code == HTTP_SEEOTHER) {
            fprintf(stdout, "REDIRECTING\n");
            //NSDictionary *headers = kurt_request_headers_helper(req);
            return;                               // this is not handled yet.
        }
        fprintf(stdout, "FAILED to get OK (response = %d)\n", req->response_code);
    }
    else if (evhttp_find_header(req->input_headers, "Content-Type") == NULL) {
        fprintf(stdout, "FAILED to find Content-Type\n");
    }
    else {
        data = [NSData dataWithBytes:EVBUFFER_DATA(req->input_buffer) length:EVBUFFER_LENGTH(req->input_buffer)];
    }
    NuBlock *block = (NuBlock *) arg;
    NuCell *args = [[NuCell alloc] init];
    [args setCar:data];
    [block evalWithArguments:args context:nil];
    [block release];
    [args release];
    fprintf(stdout, "end of callback\n");
    // leaking...
    //evhttp_connection_free(req->evcon);
}

- (void) getResourceFromHost:(NSString *) host address:(NSString *) address port:(int)port path:(NSString *)path andDo:(NuBlock *) block
{
    [block retain];
    // make the connection
    struct evhttp_connection *evcon = evhttp_connection_new([address cStringUsingEncoding:NSUTF8StringEncoding], port);
    if (evcon == NULL) {
        fprintf(stdout, "FAILED to connect\n");
        NuCell *args = [[NuCell alloc] init];
        [block evalWithArguments:args context:nil];
        [block release];
        [args release];
        return;
    }
    // make the request
    struct evhttp_request *req = evhttp_request_new(kurt_http_request_done, block);
    evhttp_add_header(req->output_headers, "Host", [host cStringUsingEncoding:NSUTF8StringEncoding]);
    // give ownership of the request to the connection
    if (evhttp_make_request(evcon, req, EVHTTP_REQ_GET, [path cStringUsingEncoding:NSUTF8StringEncoding]) == -1) {
        fprintf(stdout, "FAILED to make the request \n");
    }
}

- (void) postDataToHost:(NSString *) host address:(NSString *) address port:(int)port path:(NSString *)path data:(NSData *) data andDo:(NuBlock *) block
{
    [block retain];
    // make the connection
    struct evhttp_connection *evcon = evhttp_connection_new([address cStringUsingEncoding:NSUTF8StringEncoding], port);
    if (evcon == NULL) {
        fprintf(stdout, "FAILED to connect\n");
        NuCell *args = [[NuCell alloc] init];
        [block evalWithArguments:args context:nil];
        [block release];
        [args release];
        return;
    }
    // make the request
    struct evhttp_request *req = evhttp_request_new(kurt_http_request_done, block);
    evhttp_add_header(req->output_headers, "Host", [host cStringUsingEncoding:NSUTF8StringEncoding]);
    evhttp_add_header(req->output_headers, "Content-Length", [[NSString stringWithFormat:@"%d", [data length]] cStringUsingEncoding:NSUTF8StringEncoding]);
    evhttp_add_header(req->output_headers, "Content-Type", "application/x-www-form-urlencoded");
    evbuffer_add(req->output_buffer, [data bytes], [data length]);

    // give ownership of the request to the connection
    if (evhttp_make_request(evcon, req, EVHTTP_REQ_POST, [path cStringUsingEncoding:NSUTF8StringEncoding]) == -1) {
        fprintf(stdout, "FAILED to make the request \n");
    }
}

@end

@implementation Kurt

static Kurt *sharedKurt = nil;

+ (Kurt *) kurt
{
    NSLog(@"[Kurt kurt] should be overridden in nu/kurt.nu; is Kurt installed correctly?");
    assert(0);
    return nil;
}

+ (Kurt *) bareKurt
{
    if (!sharedKurt)
        sharedKurt = [[ConcreteKurt alloc] init];
    return sharedKurt;
}

+ (void) setVerbose:(BOOL) v
{
    verbose_kurt = v;
}

+ (BOOL) verbose {return verbose_kurt;}

- (void) run
{
}

- (int) bindToAddress:(NSString *) address port:(int) port
{
    return 0;
}

- (void) setDelegate:(id) d
{
}

- (id) delegate
{
    return nil;
}

static NSMutableDictionary *mimeTypes = nil;

+ (NSMutableDictionary *) mimeTypes
{
    return mimeTypes;
}

+ (void) setMimeTypes:(NSMutableDictionary *) dictionary
{
    [dictionary retain];
    [mimeTypes release];
    mimeTypes = dictionary;
}

+ (NSString *) mimeTypeForFileWithName:(NSString *) pathName
{
    if (mimeTypes) {
        NSString *suffix = [[pathName componentsSeparatedByString:@"."] lastObject];
        NSString *mimeType = [mimeTypes objectForKey:suffix];
        if (mimeType)
            return mimeType;
    }
    // default
    return @"text/html; charset=utf-8";
}

@end

int KurtMain(int argc, const char *argv[], NSString *KurtDelegateClassName)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    int port = 5000;
    NSString *site = @".";

    BOOL localOnly = NO;
    int i = 0;
    while (i < argc) {
        if (!strcmp(argv[i], "-s") ||
        !strcmp(argv[i], "--site")) {
            if (++i < argc) {
                site = [[[NSString alloc] initWithCString:argv[i]] autorelease];
            }
        }
        else if (!strcmp(argv[i], "-p") ||
        !strcmp(argv[i], "--port")) {
            if (++i < argc) {
                port = atoi(argv[i]);
            }
        }
        else if (!strcmp(argv[i], "-l") ||
        !strcmp(argv[i], "--local")) {
            localOnly = YES;
        }
        else if (!strcmp(argv[i], "-v") ||
        !strcmp(argv[i], "--verbose")) {
            [Kurt setVerbose:YES];
        }
        i++;
    }

    Kurt *kurt = [Kurt bareKurt];
    int status;
    if (localOnly) {
        status = [kurt bindToAddress:@"127.0.0.1" port:port];
    }
    else {
        status = [kurt bindToAddress:@"0.0.0.0" port:port];
    }
    if (status != 0) {
        NSLog(@"Unable to start service on port %d. Is another server running?", port);
    }
    else {
        Class KurtDelegateClass = KurtDelegateClassName ?  NSClassFromString(KurtDelegateClassName) : [KurtDefaultDelegate class];
        id<KurtDelegate> delegate = [[[KurtDelegateClass alloc] init] autorelease];
        [kurt setDelegate:delegate];
        [delegate configureSite:site];
        if ([delegate respondsToSelector:@selector(applicationDidFinishLaunching)]) {
            [delegate applicationDidFinishLaunching];
        }
        if ([Kurt verbose]) {
            [delegate dump];
        }
        [kurt run];
    }
    [pool drain];
    return 0;
}
