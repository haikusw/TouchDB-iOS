//
//  TDHTTPResponse.m
//  TouchDB
//
//  Created by Jens Alfke on 12/29/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "TDHTTPResponse.h"
#import "TDHTTPConnection.h"
#import "TDListener.h"
#import "TDRouter.h"
#import "TDBody.h"

#import "Logging.h"


@interface TDHTTPResponse ()
- (void) onResponseReady: (TDResponse*)response;
- (void) onDataAvailable: (NSData*)data finished: (BOOL)finished;
- (void) onFinished;
@end



@implementation TDHTTPResponse


- (id) initWithRouter: (TDRouter*)router forConnection:(TDHTTPConnection*)connection {
    self = [super init];
    if (self) {
        _router = [router retain];
        _connection = connection;
        router.onResponseReady = ^(TDResponse* r) {
            [self onResponseReady: r];
        };
        router.onDataAvailable = ^(NSData* data, BOOL finished) {
            [self onDataAvailable: data finished: finished];
        };
        router.onFinished = ^{
            [self onFinished];
        };
        
        // Run the router, synchronously:
        LogTo(TDListenerVerbose, @"%@: Starting...", self);
        [router start];
        LogTo(TDListenerVerbose, @"%@: Returning from -init", self);
    }
    return self;
}

- (void)dealloc {
    [_router release];
    [_response release];
    [_data release];
    [super dealloc];
}


- (NSString*) description {
    return [NSString stringWithFormat: @"Response[%@ %@]",
                                        _router.request.HTTPMethod, _router.request.URL.path];
}


/**
 * If you don't know the content-length in advance,
 * implement this method in your custom response class and return YES.
 **/
- (BOOL) isChunked {
    @synchronized(self) {
        if (!_askedIfChunked) {
            _chunked = !_finished;
        }
        LogTo(TDListenerVerbose, @"%@ answers isChunked=%d", self, _chunked);
        return _chunked;
    }
}


- (BOOL) delayResponeHeaders {  // [sic]
    @synchronized(self) {
        LogTo(TDListenerVerbose, @"%@ answers delayResponeHeaders=%d", self, !_response);
        if (!_response)
            _delayedHeaders = YES;
        return !_response;
    }
}


- (void) onResponseReady: (TDResponse*)response {
    @synchronized(self) {
        _response = [response retain];
        LogTo(TDListener, @"    %@ --> %i", self, _response.status);
        if (_delayedHeaders)
            [_connection responseHasAvailableData: self];
    }
}


- (NSInteger) status {
    LogTo(TDListenerVerbose, @"%@ answers status=%d", self, _response.status);
    return _response.status;
}

- (NSDictionary *) httpHeaders {
    LogTo(TDListenerVerbose, @"%@ answers httpHeaders={%d headers}", self, _response.headers.count);
    return _response.headers;
}


- (void) onDataAvailable: (NSData*)data finished: (BOOL)finished {
    @synchronized(self) {
        LogTo(TDListenerVerbose, @"%@ adding %u bytes", self, (unsigned)data.length);
        if (_data)
            [_data appendData: data];
        else
            _data = [data mutableCopy];
        if (finished)
            [self onFinished];
        else if (_chunked)
            [_connection responseHasAvailableData: self];
    }
}


@synthesize offset=_offset;


- (UInt64) contentLength {
    @synchronized(self) {
        if (!_finished)
            return 0;
        return _dataOffset + _data.length;
    }
}


- (NSData*) readDataOfLength: (NSUInteger)length {
    @synchronized(self) {
        NSAssert(_offset >= _dataOffset, @"Invalid offset %llu, min is %llu", _offset, _dataOffset);
        NSRange range;
        range.location = (NSUInteger)(_offset - _dataOffset);
        if (range.location >= _data.length) {
            LogTo(TDListenerVerbose, @"%@ sending nil bytes", self);
            return nil;
        }
        NSUInteger bytesAvailable = _data.length - range.location;
        range.length = MIN(length, bytesAvailable);
        NSData* result = [_data subdataWithRange: range];
        _offset += range.length;
        if (range.length == bytesAvailable) {
            // Client has read all of the available data, so we can discard it
            _dataOffset += _data.length;
            [_data autorelease];
            _data = nil;
        }
        LogTo(TDListenerVerbose, @"%@ sending %u bytes", self, result.length);
        return result;
    }
}


- (BOOL) isDone {
    LogTo(TDListenerVerbose, @"%@ answers isDone=%d", self, _finished);
    return _finished;
}


- (void) onFinished {
    @synchronized(self) {
        if (_finished)
            return;
        _finished = true;
        _askedIfChunked = true;

        LogTo(TDListenerVerbose, @"%@ Finished!", self);

        // Break cycles:
        _router.onResponseReady = nil;
        _router.onDataAvailable = nil;
        _router.onFinished = nil;

        if (!_chunked || _offset == 0) {
            // Response finished immediately, before the connection asked for any data, so we're free
            // to massage the response:
            LogTo(TDListenerVerbose, @"%@ prettifying response body", self);
#if DEBUG
            BOOL pretty = YES;
#else
            BOOL pretty = [_router boolQuery: @"pretty"];
#endif
            if (pretty) {
                [_data release];
                _data = [_response.body.asPrettyJSON mutableCopy];
            }
        }
        [_connection responseHasAvailableData: self];
    }
}


- (void)connectionDidClose {
    _connection = nil;
    [_data release];
    _data = nil;
}


@end
