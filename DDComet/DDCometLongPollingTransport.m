
#import "DDCometLongPollingTransport.h"
#import "DDCometClient.h"
#import "DDCometMessage.h"
#import "DDQueue.h"
//#import "SBJson.h"
#import <Foundation/NSJSONSerialization.h>

@interface DDCometLongPollingTransport ()

- (NSURLConnection *)sendMessages:(NSArray *)messages;
- (NSArray *)outgoingMessages;
- (NSURLRequest *)requestWithMessages:(NSArray *)messages;
- (id)keyWithConnection:(NSURLConnection *)connection;

@end

@implementation DDCometLongPollingTransport

- (id)initWithClient:(DDCometClient *)client
{
	if ((self = [super init]))
	{
		m_client = [client retain];
		m_responseDatas = [[NSMutableDictionary alloc] initWithCapacity:2];
	}
	return self;
}

- (void)dealloc
{
	[m_responseDatas release], m_responseDatas = nil;
	[m_client release], m_client = nil;
	[super dealloc];
}

- (void)start
{
	[self performSelectorInBackground:@selector(main) withObject:nil];
}

- (void)cancel
{
	m_shouldCancel = YES;
}

#pragma mark -

- (void)main
{
	do
	{
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSArray *messages = [self outgoingMessages];
		
		BOOL isPolling = NO;
		if ([messages count] == 0)
		{
			if (m_client.state == DDCometStateConnected)
			{
				isPolling = YES;
				DDCometMessage *message = [DDCometMessage messageWithChannel:@"/meta/connect"];
				message.clientID = m_client.clientID;
				message.connectionType = @"long-polling";
				DDCometDLog(@"Sending long-poll message: %@", message);
				messages = [NSArray arrayWithObject:[message proxyForJson]];
			}
			else
			{
				[NSThread sleepForTimeInterval:0.01];
			}
		}
		
		NSURLConnection *connection = [self sendMessages:messages];
		if (connection)
		{
			NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
			while ([runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]])
			{
				if (isPolling)
				{
					if (m_shouldCancel)
					{
						m_shouldCancel = NO;
						[connection cancel];
					}
					else
					{
						messages = [self outgoingMessages];
						[self sendMessages:messages];
					}
				}
			}
		}
		[pool release];
	} while (m_client.state != DDCometStateDisconnected);
}

- (NSURLConnection *)sendMessages:(NSArray *)messages
{
	NSURLConnection *connection = nil;
	if ([messages count] != 0)
	{
		NSURLRequest *request = [self requestWithMessages:messages];
		connection = [NSURLConnection connectionWithRequest:request delegate:self];
		if (connection)
		{
			NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
			[connection scheduleInRunLoop:runLoop forMode:[runLoop currentMode]];
			[connection start];
		}
	}
	return connection;
}

- (NSArray *)outgoingMessages
{
	NSMutableArray *messages = [NSMutableArray array];
	DDCometMessage *message;
	id<DDQueue> outgoingQueue = [m_client outgoingQueue];
	while ((message = [outgoingQueue removeObject]))
		[messages addObject:[message proxyForJson]];
	return messages;
}

- (NSURLRequest *)requestWithMessages:(NSArray *)messages
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:m_client.endpointURL];
	
	//SBJsonWriter *jsonWriter = [[SBJsonWriter alloc] init];
    //NSData *body = [jsonWriter dataWithObject:messages];
    //[jsonWriter release];
    NSError *error = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:messages options:kNilOptions error:&error];
    
    if(error)
        return nil;
	
	[request setHTTPMethod:@"POST"];
	[request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
	[request setHTTPBody:body];
	
    @synchronized(m_client)
    {
        NSNumber *timeout = [[m_client.advice objectForKey:@"timeout"] retain];
        if (timeout)
            [request setTimeoutInterval:([timeout floatValue] / 1000)];
        [timeout release];
    }
	return request;
}

- (id)keyWithConnection:(NSURLConnection *)connection
{
	return [NSNumber numberWithUnsignedInteger:[connection hash]];
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	[m_responseDatas setObject:[NSMutableData data] forKey:[self keyWithConnection:connection]];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data
{
	NSMutableData *responseData = [m_responseDatas objectForKey:[self keyWithConnection:connection]];
	[responseData appendData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection
{
	NSData *responseData = [[m_responseDatas objectForKey:[self keyWithConnection:connection]] retain];
	[m_responseDatas removeObjectForKey:[self keyWithConnection:connection]];
	
    NSError *error = nil;
    NSArray *responses = [NSJSONSerialization JSONObjectWithData:responseData options:kNilOptions error:&error];
    
	//SBJsonParser *parser = [[SBJsonParser alloc] init];
	//NSArray *responses = [parser objectWithData:responseData];
	//[parser release];
	//parser = nil;
	[responseData release];
	responseData = nil;
	
    if(error)
        return;

	id<DDQueue> incomingQueue = [m_client incomingQueue];
	
	for (NSDictionary *messageData in responses)
	{
		DDCometMessage *message = [DDCometMessage messageWithJson:messageData];
		[incomingQueue addObject:message];
	}
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error
{
	[m_responseDatas removeObjectForKey:[self keyWithConnection:connection]];
}

@end
