//
//  Logger.m
//  agent
//
//  Created by William Dillon on 3/31/10.
//  Copyright 2010 Oregon State University. All rights reserved.
//

#import "version.h"
#import "OSULogger.h"
#import <stdarg.h>

static OSULogger *sharedLogger = nil;

void OSULog(NSString *format, ... )
{
	va_list arguments;
	va_start(arguments, format);
	NSString *tempString = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	
	[[OSULogger sharedLogger] logString:tempString];
	[tempString release];
}

void OSULogs(NSInteger severity, NSString *format, ... )
{
	va_list arguments;
	va_start(arguments, format);
	NSString *tempString = [[NSString alloc] initWithFormat:format arguments:arguments];
	va_end(arguments);
	
	[[OSULogger sharedLogger] logString:tempString
						   withSeverity:severity];
	[tempString release];
}

@implementation OSULogger

@synthesize delegate;

+ (OSULogger *)sharedLogger
{
	static dispatch_once_t pred;
	dispatch_once(&pred, ^{
		sharedLogger = [[OSULogger alloc] init];
	});
		
	return sharedLogger;
}

+ (char *)version
{
	return GIT_COMMIT;
}

- (void)dealloc
{
	asl_close(aslClient);
	OSULogs(LOG_WARN, @"Over release of \"OSULogger\".");
	[super dealloc];
}

- (id)init
{
	self = [super init];
	if (self == nil) {
		return self;
	}
	
	// Create a root node, and note the time
	root = [[NSXMLElement alloc] initWithName:@"log"];
	[root addAttribute:[NSXMLNode attributeWithName:@"timestamp" stringValue:[[NSDate date] description]]];
//	[root addAttribute:[NSXMLNode attributeWithName:@"xmlns:xsi"
//										stringValue:@"http://www.w3.org/2001/XMLSchema-instance"]];
//	[root addAttribute:[NSXMLNode attributeWithName:@"xsi:schemaLocation"
//										stringValue:@"http://tundra.oce.orst.edu/dist-opencl/logSchema.xsd"]];

	// Create the logging document
	document = [[NSXMLDocument alloc] initWithRootElement:root];
	[document setCharacterEncoding:@"UTF-8"];
	
	// Create a date formatter (for fractional seconds)
	formatter = [[NSDateFormatter alloc] init];
	[formatter setFormatterBehavior:NSDateFormatterBehavior10_4];
	[formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss.SSS"];
	
	// Create an Apple System Log client instance
//	aslClient = NULL;
	// Make absolutely sure that it's created and used on the same thread
//	dispatch_async(dispatch_get_main_queue(), ^{
		aslClient = asl_open("DistOpenCLAgent", "edu.oregonstate.DistOpenCL", 0);
//	});
	
	// Insert a log message about starting up
	[self logString:@"Started OSULogger."
		   withFile:[NSString stringWithCString:__FILE__ encoding:NSUTF8StringEncoding]
			   line:__LINE__
			version:[NSString stringWithCString:GIT_COMMIT encoding:NSUTF8StringEncoding]
		andSeverity:LOG_INFO];
	
	return self;
}

- (void)logString:(NSString *)string
{
	[self logString:string withSeverity:LOG_NONE];
	
	return;
}

- (void)logString:(NSString *)string withSeverity:(NSInteger)severity
{
	NSXMLElement *eventElement = [NSXMLElement elementWithName:@"event" stringValue:string];
	NSXMLNode *attribute = nil;
	
	int asl_severity;
	
	switch (severity) {
		case LOG_FAIL:
			attribute = [NSXMLNode attributeWithName:@"severity" stringValue:@"Failure"];
			asl_severity = ASL_LEVEL_ERR;
			break;
		case LOG_WARN:
			attribute = [NSXMLNode attributeWithName:@"severity" stringValue:@"Warning"];
			asl_severity = ASL_LEVEL_WARNING;
			break;
		case LOG_INFO:
			attribute = [NSXMLNode attributeWithName:@"severity" stringValue:@"Information"];
			asl_severity = ASL_LEVEL_INFO;
			break;
		case LOG_DEBUG:
		default:
			attribute = [NSXMLNode attributeWithName:@"severity" stringValue:@"Debug"];
			asl_severity = ASL_LEVEL_DEBUG;
			break;
	}
	
	// DTrace static probe for logger
//	if (OSULOGGER_LOGGER_ENABLED()) {
//		OSULOGGER_LOGGER((char *)[string UTF8String]);
//	}

	// A given asl client should only be called from one thread.
	// We'll sacrifice some of the time accuracy in the ASL structure
	// and use GCD to ensure that by scheduling it on the main thread
//	dispatch_async(dispatch_get_main_queue(), ^{
		asl_log(aslClient, NULL, asl_severity, "%s", [string cStringUsingEncoding:NSUTF8StringEncoding]);
//	});

//	asl_log(NULL, NULL, asl_severity, "%s", [string cStringUsingEncoding:NSUTF8StringEncoding]);

	if (attribute != nil) {
		[eventElement addAttribute:attribute];

#ifdef DEBUG
		NSLog(@"%@: %@", [attribute stringValue], string);
#endif
	} else {
#ifdef DEBUG
		NSLog(@"%@", string);
#endif
	}

	[eventElement addAttribute:[NSXMLNode attributeWithName:@"timestamp"
												stringValue:[formatter stringFromDate:[NSDate date]]]];
	
	if( delegate ) {
		if( [delegate respondsToSelector:@selector(logUpdatedString:)] ) {
			[delegate logUpdatedString:[NSString stringWithFormat:@"%@: %@: %@\n",
										[[eventElement attributeForName:@"timestamp"] stringValue],
										[[eventElement attributeForName:@"severity"] stringValue],
										[eventElement stringValue]]];
		} else if( [delegate respondsToSelector:@selector(logUpdatedXML:)] ) { 
			[delegate logUpdatedXML:[[eventElement copy] autorelease]];
		}
	}

	@synchronized(root) {
        [root addChild:eventElement];
    }	
	
	return;
}

- (void)logString:(NSString *)string
		 withFile:(NSString *)file
			 line:(NSInteger)line
		  version:(NSString *)version
	  andSeverity:(NSInteger)severity
{
	// It's possible that the __FILE__ macro includes the full path.
	// We only really want the filename.
	NSArray *pathCompontents = [file componentsSeparatedByString:@"/"];
	
	[self logString:[NSString stringWithFormat:@"%@:%d:%@: %@",
					 [pathCompontents objectAtIndex:[pathCompontents count] - 1],
					 line,
					 version,
					 string]
	   withSeverity:severity];
}

- (void)logUsingFormat:(NSString *)format, ...
{
	va_list argumentList;
	
	NSString *tempString = [NSString stringWithFormat:format, argumentList];
	
	[self logString:tempString];
}

- (NSString *)stringValue
{
	NSMutableString *temp = [[NSMutableString alloc] init];
	NSArray *children;
	
	@synchronized(root) {
		children = [root children];
	}
	
	@synchronized(children) {
        for(NSXMLElement *element in children) {
            // Print a nicely formated line for each entry
            [temp appendFormat:@"%@: %@: %@\n",
             [[element attributeForName:@"timestamp"] stringValue],
             [[element attributeForName:@"severity"] stringValue],
             [element stringValue]];
        }
    }
	
	return [temp autorelease];
}

- (NSString *)description
{
	// I know this is naughty, but see the definition of this function above ;)
	NSMutableString *temp = (NSMutableString *)[self stringValue];
	
	// Print log header:
    @synchronized(root) {
        [temp insertString:[NSString stringWithFormat:@"Log beginning at: %@ with %d entries.\n",
							[[root attributeForName:@"beginning"] stringValue],
							[root childCount]]
				   atIndex:0];
    }
	
	return temp;
}

@synthesize document;

@end