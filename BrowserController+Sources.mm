//
//  BrowserController+Sources.m
//  OsiriX
//
//  Created by Alessandro Volz on 06.05.11.
//  Copyright 2011 OsiriX Team. All rights reserved.
//

#import "BrowserController+Sources.h"
#import "BrowserController+Sources+Copy.h"
#import "BrowserSource.h"
#import "ImageAndTextCell.h"
#import "DicomDatabase.h"
#import "RemoteDicomDatabase.h"
#import "NSManagedObject+N2.h"
#import "DicomImage.h"
#import "MutableArrayCategory.h"
#import "NSImage+N2.h"
#import "NSUserDefaultsController+N2.h"
#import "N2Debug.h"
#import "NSThread+N2.h"
#import "N2Operators.h"
#import "ThreadModalForWindowController.h"
#import "BonjourPublisher.h"
#import "DicomFile.h"
#import "ThreadsManager.h"
#import "NSDictionary+N2.h"
#import "NSFileManager+N2.h"
#import "DCMNetServiceDelegate.h"
#import "AppController.h"
#import <netinet/in.h>
#import <arpa/inet.h>
#import "DicomDatabase+Scan.h"

/*
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
*/

@interface BrowserSourcesHelper : NSObject/*<NSTableViewDelegate,NSTableViewDataSource>*/ {
	BrowserController* _browser;
	NSNetServiceBrowser* _nsbOsirix;
	NSNetServiceBrowser* _nsbDicom;
	NSMutableDictionary* _bonjourSources;
}

-(id)initWithBrowser:(BrowserController*)browser;
-(void)_analyzeVolumeAtPath:(NSString*)path;

@end

@interface DefaultBrowserSource : BrowserSource
@end

@interface BonjourBrowserSource : BrowserSource {
	NSNetService* _service;
}

@property(retain) NSNetService* service;

-(NSInteger)port;

@end

@interface MountedBrowserSource : BrowserSource {
	NSString* _devicePath;
	DicomDatabase* _database;
}

@property(retain) NSString* devicePath;

+(id)browserSourceForDevicePath:(NSString*)devicePath description:(NSString*)description dictionary:(NSDictionary*)dictionary;

@end



@implementation BrowserController (Sources)

-(void)awakeSources {
	[_sourcesArrayController setSortDescriptors:[NSArray arrayWithObjects: [[[NSSortDescriptor alloc] initWithKey:@"self" ascending:YES] autorelease], NULL]];
	[_sourcesArrayController setAutomaticallyRearrangesObjects:YES];
	[_sourcesArrayController addObject:[DefaultBrowserSource browserSourceForLocalPath:DicomDatabase.defaultDatabase.baseDirPath]];
	[_sourcesArrayController setSelectsInsertedObjects:NO];
	
	_sourcesHelper = [[BrowserSourcesHelper alloc] initWithBrowser:self];
	[_sourcesTableView setDataSource:_sourcesHelper];
	[_sourcesTableView setDelegate:_sourcesHelper];
	
	ImageAndTextCell* cell = [[[ImageAndTextCell alloc] init] autorelease];
	[cell setEditable:NO];
	[cell setLineBreakMode:NSLineBreakByTruncatingMiddle];
	[[_sourcesTableView tableColumnWithIdentifier:@"Source"] setDataCell:cell];
	
	[_sourcesTableView registerForDraggedTypes:[NSArray arrayWithObject:O2AlbumDragType]];
	
	[_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

-(void)deallocSources {
	[_sourcesHelper release]; _sourcesHelper = nil;
}

-(NSInteger)sourcesCount {
	return [[_sourcesArrayController arrangedObjects] count];
}

-(BrowserSource*)sourceAtRow:(int)row {
	return ([_sourcesArrayController.arrangedObjects count] > row)? [_sourcesArrayController.arrangedObjects objectAtIndex:row] : nil;
}

-(int)rowForSource:(BrowserSource*)source {
	for (NSInteger i = 0; i < [[_sourcesArrayController arrangedObjects] count]; ++i)
		if ([[_sourcesArrayController.arrangedObjects objectAtIndex:i] isEqualToSource:source])
			return i;
	return -1;
}

-(BrowserSource*)sourceForDatabase:(DicomDatabase*)database {
	if (database.isLocal)
		return [BrowserSource browserSourceForLocalPath:database.baseDirPath];
	else return [BrowserSource browserSourceForAddress:[NSString stringWithFormat:@"%@:%d", [(RemoteDicomDatabase*)database address], [(RemoteDicomDatabase*)database port]] description:nil dictionary:nil];	
}

-(int)rowForDatabase:(DicomDatabase*)database {
	return [self rowForSource:[self sourceForDatabase:database]];
}

-(void)selectSourceForDatabase:(DicomDatabase*)database {
	NSInteger row = [self rowForDatabase:database];
	if (row >= 0)
		[_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
	else NSLog(@"Warning: couldn't find database in sources (%@)", database);
}

-(void)selectCurrentDatabaseSource {
	if (!_database) {
		[_sourcesTableView selectRowIndexes:[NSIndexSet indexSet] byExtendingSelection:NO];
		return;
	}
	
	NSInteger i = [self rowForDatabase:_database];
	if (i == -1) {
		NSDictionary* source = [NSDictionary dictionaryWithObjectsAndKeys: [_database.baseDirPath stringByDeletingLastPathComponent], @"Path", [_database.baseDirPath.stringByDeletingLastPathComponent.lastPathComponent stringByAppendingString:@" DB"], @"Description", nil];
		[NSUserDefaults.standardUserDefaults setObject:[[NSUserDefaults.standardUserDefaults objectForKey:@"localDatabasePaths"] arrayByAddingObject:source] forKey:@"localDatabasePaths"];
		i = [self rowForDatabase:_database];
	} if (i != [_sourcesTableView selectedRow])
		[_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
}

-(void)setDatabaseThread:(NSArray*)io {
	NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
	@try {
		NSString* type = [io objectAtIndex:0];
		DicomDatabase* db = nil;
		
		if ([type isEqualToString:@"Local"]) {
			NSString* path = [io objectAtIndex:1];
			if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
				NSString* message = NSLocalizedString(@"The selected database's data was not found on your computer.", nil);
				if ([path hasPrefix:@"/Volumes/"])
					  message = [message stringByAppendingFormat:@" %@", NSLocalizedString(@"If it is stored on an external drive? If so, please make sure the device in connected and on.", nil)];
				[NSException raise:NSGenericException format:message];
			}
			
			NSString* name = io.count > 2? [io objectAtIndex:2] : nil;
			db = [DicomDatabase databaseAtPath:path name:name];
		}
		
		if ([type isEqualToString:@"Remote"]) {
			NSString* address = [io objectAtIndex:1];
			NSInteger port = [[io objectAtIndex:2] intValue];
			NSString* name = io.count > 3? [io objectAtIndex:3] : nil;
			NSString* ap = [NSString stringWithFormat:@"%@:%d", address, port];
			db = [RemoteDicomDatabase databaseForAddress:ap name:name];
		}
		
		[self performSelectorOnMainThread:@selector(setDatabase:) withObject:db waitUntilDone:NO];
	} @catch (NSException* e) {
		[self performSelectorOnMainThread:@selector(selectCurrentDatabaseSource) withObject:nil waitUntilDone:NO];
		if (![e.description isEqualToString:@"Cancelled."]) {
			N2LogExceptionWithStackTrace(e);
			[self performSelectorOnMainThread:@selector(_complain:) withObject:[NSArray arrayWithObjects: [NSNumber numberWithFloat:0.1], NSLocalizedString(@"Error", nil), e.description, NULL] waitUntilDone:NO];
		}
	} @finally {
		[pool release];
	}
}

-(void)_complain:(NSArray*)why { // if 1st obj in array is a number then execute this after the delay specified by that number, with the rest of the array
	if ([[why objectAtIndex:0] isKindOfClass:NSNumber.class])
		[self performSelector:@selector(_complain:) withObject:[why subarrayWithRange:NSMakeRange(1, why.count-1)] afterDelay:[[why objectAtIndex:0] floatValue]];
	else NSBeginAlertSheet([why objectAtIndex:0], nil, nil, nil, self.window, NSApp, @selector(endSheet:), nil, nil, [why objectAtIndex:1]);
}

-(NSThread*)initiateSetDatabaseAtPath:(NSString*)path name:(NSString*)name {
	NSArray* io = [NSMutableArray arrayWithObjects: @"Local", path, name, nil];
	
	NSThread* thread = [[NSThread alloc] initWithTarget:self selector:@selector(setDatabaseThread:) object:io];
	thread.name = NSLocalizedString(@"Loading OsiriX database...", nil);
	thread.supportsCancel = YES;
	thread.status = NSLocalizedString(@"Reading data...", nil);
	
	ThreadModalForWindowController* tmc = [thread startModalForWindow:self.window];
	[thread start];
	
	return [thread autorelease];
}

-(NSThread*)initiateSetRemoteDatabaseWithAddress:(NSString*)address port:(NSInteger)port name:(NSString*)name {
	NSArray* io = [NSMutableArray arrayWithObjects: @"Remote", address, [NSNumber numberWithInteger:port], name, nil];
	
	NSThread* thread = [[NSThread alloc] initWithTarget:self selector:@selector(setDatabaseThread:) object:io];
	thread.name = NSLocalizedString(@"Loading remote OsiriX database...", nil);
	thread.supportsCancel = YES;
	ThreadModalForWindowController* tmc = [thread startModalForWindow:self.window];
	[thread start];
	
	return [thread autorelease];
}

-(void)setDatabaseFromSource:(BrowserSource*)source {
	if ([source isEqualToSource:[self sourceForDatabase:_database]])
		return;
	
	DicomDatabase* db = [source database];
	
	if (db) 
		[self setDatabase:db];
	else
		switch (source.type) {
			case BrowserSourceTypeLocal: {
				[self initiateSetDatabaseAtPath:source.location name:source.description];
			} break;
			case BrowserSourceTypeRemote: {
				NSString* host; NSInteger port; [RemoteDicomDatabase address:source.location toAddress:&host port:&port];
				[self initiateSetRemoteDatabaseWithAddress:host port:port name:source.description];
			} break;
			default: {
				NSBeginAlertSheet(NSLocalizedString(@"DICOM Destination", nil), nil, nil, nil, self.window, NSApp, @selector(endSheet:), nil, nil, NSLocalizedString(@"It is a DICOM destination node: you cannot browse its content. You can only drag & drop studies on them.", nil));
				[self selectCurrentDatabaseSource];
			} break;
		}
}

-(void)redrawSources {
	[_sourcesTableView setNeedsDisplay:YES];
}

-(long)currentBonjourService { // __deprecated
	return [_sourcesTableView selectedRow]-1;
}

-(void)setCurrentBonjourService:(int)index { // __deprecated
	[_sourcesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:index+1] byExtendingSelection:NO];
}

-(int)findDBPath:(NSString*)path dbFolder:(NSString*)DBFolderLocation { // __deprecated
	NSInteger i = [self rowForSource:[BrowserSource browserSourceForLocalPath:path]];
	if (i == -1) i = [self rowForSource:[BrowserSource browserSourceForLocalPath:DBFolderLocation]];
	return i;
}

@end

@implementation BrowserSourcesHelper

static void* const LocalBrowserSourcesContext = @"LocalBrowserSourcesContext";
static void* const RemoteBrowserSourcesContext = @"RemoteBrowserSourcesContext";
static void* const DicomBrowserSourcesContext = @"DicomBrowserSourcesContext";
static void* const SearchBonjourNodesContext = @"SearchBonjourNodesContext";
static void* const SearchDicomNodesContext = @"SearchDicomNodesContext";

-(id)initWithBrowser:(BrowserController*)browser {
	if ((self = [super init])) {
		_browser = browser;
		[NSUserDefaultsController.sharedUserDefaultsController addObserver:self forValuesKey:@"localDatabasePaths" options:NSKeyValueObservingOptionInitial context:LocalBrowserSourcesContext];
		[NSUserDefaultsController.sharedUserDefaultsController addObserver:self forValuesKey:@"OSIRIXSERVERS" options:NSKeyValueObservingOptionInitial context:RemoteBrowserSourcesContext];
		[NSUserDefaultsController.sharedUserDefaultsController addObserver:self forValuesKey:@"SERVERS" options:NSKeyValueObservingOptionInitial context:DicomBrowserSourcesContext];
		_bonjourSources = [[NSMutableDictionary alloc] init];
		[NSUserDefaultsController.sharedUserDefaultsController addObserver:self forValuesKey:@"searchDICOMBonjour" options:NSKeyValueObservingOptionInitial context:SearchDicomNodesContext];
		[NSUserDefaultsController.sharedUserDefaultsController addObserver:self forValuesKey:@"DoNotSearchForBonjourServices" options:NSKeyValueObservingOptionInitial context:SearchBonjourNodesContext];
		_nsbOsirix = [[NSNetServiceBrowser alloc] init];
		[_nsbOsirix setDelegate:self];
		[_nsbOsirix searchForServicesOfType:@"_osirixdb._tcp." inDomain:@""];
		_nsbDicom = [[NSNetServiceBrowser alloc] init];
		[_nsbDicom setDelegate:self];
		[_nsbDicom searchForServicesOfType:@"_dicom._tcp." inDomain:@""];
		// mounted devices
		[NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(_observeVolumeNotification:) name:NSWorkspaceDidMountNotification object:nil];
		[NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(_observeVolumeNotification:) name:NSWorkspaceDidUnmountNotification object:nil];
		[NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(_observeVolumeWillUnmountNotification:) name:NSWorkspaceWillUnmountNotification object:nil];
		for (NSString* path in [NSWorkspace.sharedWorkspace mountedRemovableMedia])
			[self _analyzeVolumeAtPath:path];
	}
	
	return self;
}

-(void)dealloc {
	[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceDidMountNotification object:nil];
	[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceDidUnmountNotification object:nil];
	[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceWillUnmountNotification object:nil];
	[_nsbDicom release]; _nsbDicom = nil;
	[_nsbOsirix release]; _nsbOsirix = nil;
	[NSUserDefaultsController.sharedUserDefaultsController removeObserver:self forValuesKey:@"DoNotSearchForBonjourServices"];
	[NSUserDefaultsController.sharedUserDefaultsController removeObserver:self forValuesKey:@"searchDICOMBonjour"];
	[_bonjourSources release];
	[NSUserDefaultsController.sharedUserDefaultsController removeObserver:self forValuesKey:@"SERVERS"];
	[NSUserDefaultsController.sharedUserDefaultsController removeObserver:self forValuesKey:@"OSIRIXSERVERS"];
	[NSUserDefaultsController.sharedUserDefaultsController removeObserver:self forValuesKey:@"localDatabasePaths"];
//	[[NSUserDefaults.standardUserDefaults objectForKey:@"localDatabasePaths"] removeObserver:self forValuesKey:@"values"];
	_browser = nil;
	[super dealloc];
}

-(void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
	NSKeyValueChange changeKind = [[change valueForKey:NSKeyValueChangeKindKey] unsignedIntegerValue];
	
	if (context == LocalBrowserSourcesContext) {
		NSArray* a = [NSUserDefaults.standardUserDefaults objectForKey:@"localDatabasePaths"];
		// remove old items
		for (NSInteger i = [[_browser.sources arrangedObjects] count]-1; i >= 0; --i) {
			BrowserSource* is = [_browser.sources.arrangedObjects objectAtIndex:i];
			if (is.type == BrowserSourceTypeLocal && ![is isKindOfClass:DefaultBrowserSource.class])
				if (![[a valueForKey:@"Path"] containsObject:is.location])
					[_browser.sources removeObjectAtArrangedObjectIndex:i];
		}
		// add new items
		for (NSDictionary* d in a) {
			NSString* dpath = [d valueForKey:@"Path"];
			if ([[DicomDatabase baseDirPathForPath:dpath] isEqualToString:DicomDatabase.defaultDatabase.baseDirPath])
				continue;
			NSUInteger i = [[_browser.sources.arrangedObjects valueForKey:@"location"] indexOfObject:dpath];
			if (i == NSNotFound)
				[_browser.sources addObject:[BrowserSource browserSourceForLocalPath:dpath description:[d objectForKey:@"Description"] dictionary:d]];
			else {
				[[_browser sourceAtRow:i] setDescription:[d objectForKey:@"Description"]];
				[[_browser sourceAtRow:i] setDictionary:d];
			}
		}
	}
	
	if (context == RemoteBrowserSourcesContext) {
		NSArray* a = [NSUserDefaults.standardUserDefaults objectForKey:@"OSIRIXSERVERS"];
		// remove old items
		for (NSInteger i = [[_browser.sources arrangedObjects] count]-1; i >= 0; --i) {
			BrowserSource* is = [_browser.sources.arrangedObjects objectAtIndex:i];
			if (is.type == BrowserSourceTypeRemote)
				if (![[a valueForKey:@"Address"] containsObject:is.location])
					[_browser.sources removeObjectAtArrangedObjectIndex:i];
		}
		// add new items
		for (NSDictionary* d in a) {
			NSString* dadd = [d valueForKey:@"Address"];
			NSUInteger i = [[_browser.sources.arrangedObjects valueForKey:@"location"] indexOfObject:dadd];
			if (i == NSNotFound)
				[_browser.sources addObject:[BrowserSource browserSourceForAddress:dadd description:[d objectForKey:@"Description"] dictionary:d]];
			else {
				[[_browser sourceAtRow:i] setDescription:[d objectForKey:@"Description"]];
				[[_browser sourceAtRow:i] setDictionary:d];
			}
		}
	}
	
	if (context == DicomBrowserSourcesContext) {
		NSArray* a = [NSUserDefaults.standardUserDefaults objectForKey:@"SERVERS"];
		NSMutableDictionary* aa = [NSMutableDictionary dictionary];
		for (NSDictionary* ai in a)
			[aa setObject:ai forKey:[RemoteDicomDatabase addressWithHostname:[ai objectForKey:@"Address"] port:[[ai objectForKey:@"Port"] integerValue] aet:[ai objectForKey:@"AETitle"]]];
		// remove old items
		for (NSInteger i = [[_browser.sources arrangedObjects] count]-1; i >= 0; --i) {
			BrowserSource* is = [_browser.sources.arrangedObjects objectAtIndex:i];
			if (is.type == BrowserSourceTypeDicom) {
				if (![[aa allKeys] containsObject:is.location])
					[_browser.sources removeObjectAtArrangedObjectIndex:i];
			}
		}
		// add new items
		for (NSString* aai in aa) {
			NSUInteger i = [[_browser.sources.arrangedObjects valueForKey:@"location"] indexOfObject:aai];
			if (i == NSNotFound)
				[_browser.sources addObject:[BrowserSource browserSourceForDicomNodeAtAddress:aai description:[[aa objectForKey:aai] objectForKey:@"Description"] dictionary:[aa objectForKey:aai]]];
			else {
				[[_browser sourceAtRow:i] setDescription:[[aa objectForKey:aai] objectForKey:@"Description"]];
				[[_browser sourceAtRow:i] setDictionary:[aa objectForKey:aai]];
			}
		}
	}
	
	if (context == SearchBonjourNodesContext) {
		if ([NSUserDefaults.standardUserDefaults boolForKey:@"DoNotSearchForBonjourServices"]) {
			for (BrowserSource* bs in [_bonjourSources allValues])
				if (bs.type == BrowserSourceTypeRemote)
					[_browser.sources removeObject:bs];
		} else {
			for (BrowserSource* bs in [_bonjourSources allValues])
				if (bs.type == BrowserSourceTypeRemote && bs.location)
					[_browser.sources addObject:bs];
		}
	}
	
	if (context == SearchDicomNodesContext) {
		if (![NSUserDefaults.standardUserDefaults boolForKey:@"searchDICOMBonjour"]) {
			for (BrowserSource* bs in [_bonjourSources allValues])
				if (bs.type == BrowserSourceTypeDicom)
					[_browser.sources removeObject:bs];
		} else {
			for (BrowserSource* bs in [_bonjourSources allValues])
				if (bs.type == BrowserSourceTypeDicom && bs.location)
					[_browser.sources addObject:bs];
		}
	}
	
	// showhide bonjour sources
}

-(void)netServiceDidResolveAddress:(NSNetService*)service {
	BrowserSource* source = [_bonjourSources objectForKey:[NSValue valueWithPointer:service]];
	if (!source) return;
	
	NSLog(@"Detected remote database: %@", service);
	
	NSMutableArray* addresses = [NSMutableArray array];
	for (NSData* address in service.addresses) {
        struct sockaddr* sockAddr = (struct sockaddr*)address.bytes;
		if (sockAddr->sa_family == AF_INET) {
			struct sockaddr_in* sockAddrIn = (struct sockaddr_in*)sockAddr;
			NSString* host = [NSString stringWithUTF8String:inet_ntoa(sockAddrIn->sin_addr)];
			NSInteger port = ntohs(sockAddrIn->sin_port);
			[addresses addObject:[NSArray arrayWithObjects: host, [NSNumber numberWithInteger:port], NULL]];
		} else
		if (sockAddr->sa_family == AF_INET6) {
			struct sockaddr_in6* sockAddrIn6 = (struct sockaddr_in6*)sockAddr;
			char buffer[256];
			const char* rv = inet_ntop(AF_INET6, &sockAddrIn6->sin6_addr, buffer, sizeof(buffer));
			NSString* host = [NSString stringWithUTF8String:buffer];
			NSInteger port = ntohs(sockAddrIn6->sin6_port);
			[addresses addObject:[NSArray arrayWithObjects: host, [NSNumber numberWithInteger:port], NULL]];
		}
	}
	
	for (NSArray* address in addresses) {
		// NSLog(@"\t%@:%@", [address objectAtIndex:0], [address objectAtIndex:1]);
		if (!source.location)
			if (source.type == BrowserSourceTypeRemote)
				source.location = [[address objectAtIndex:0] stringByAppendingFormat:@":%@", [address objectAtIndex:1]];
			else source.location = [service.name stringByAppendingFormat:@"@%@:%@", [address objectAtIndex:0], [address objectAtIndex:1]];
	}
	
	if (source.type == BrowserSourceTypeRemote)
		source.dictionary = [BonjourPublisher dictionaryFromXTRecordData:service.TXTRecordData];
	else source.dictionary = [DCMNetServiceDelegate DICOMNodeInfoFromTXTRecordData:service.TXTRecordData];
		
	if (source.location) {
//		NSLog(@"Adding %@", source.location);
		if (source.type == BrowserSourceTypeRemote && ![NSUserDefaults.standardUserDefaults boolForKey:@"DoNotSearchForBonjourServices"])
			[_browser.sources addObject:source];
		if (source.type == BrowserSourceTypeDicom && [NSUserDefaults.standardUserDefaults boolForKey:@"searchDICOMBonjour"])
			[_browser.sources addObject:source];
	}
}

-(void)netService:(NSNetService*)service didNotResolve:(NSDictionary*)errorDict {
	[_bonjourSources removeObjectForKey:[NSValue valueWithPointer:service]];
}

-(void)netServiceBrowser:(NSNetServiceBrowser*)nsb didFindService:(NSNetService*)service moreComing:(BOOL)moreComing {
	if (nsb == _nsbOsirix)
		if ([service isEqual:[[BonjourPublisher currentPublisher] netService]])
			return; // it's me
	if (nsb == _nsbDicom)
		if ([service isEqual:[[AppController sharedAppController] dicomBonjourPublisher]])
			return; // it's me
	
	NSLog(@"Bonjour service found: %@", service);
	
	BonjourBrowserSource* source;
	if (nsb == _nsbOsirix)
		source = [BonjourBrowserSource browserSourceForAddress:nil description:service.name dictionary:nil];
	else source = [BonjourBrowserSource browserSourceForDicomNodeAtAddress:nil description:service.name dictionary:nil];
	
	source.service = service;
	[_bonjourSources setObject:source forKey:[NSValue valueWithPointer:service]];
	
	// resolve the address and port for this NSNetService
	[service setDelegate:self];
	[service resolveWithTimeout:5];
}

-(void)netServiceBrowser:(NSNetServiceBrowser*)nsb didRemoveService:(NSNetService*)service moreComing:(BOOL)moreComing {
	if (nsb == _nsbOsirix)
		if ([service isEqual:[[BonjourPublisher currentPublisher] netService]])
			return; // it's me
	if (nsb == _nsbDicom)
		if ([service isEqual:[[AppController sharedAppController] dicomBonjourPublisher]])
			return; // it's me
	
	NSLog(@"Bonjour service gone: %@", service);
	
	BonjourBrowserSource* bs = nil;
	for (BonjourBrowserSource* bsi in [_bonjourSources allValues])
		if ([bsi.service isEqual:service])
			bs = bsi;
	if (!bs)
		return;
	
	if (bs.type == BrowserSourceTypeRemote && ![NSUserDefaults.standardUserDefaults boolForKey:@"DoNotSearchForBonjourServices"])
		[_browser.sources removeObject:bs];
	if (bs.type == BrowserSourceTypeDicom && [NSUserDefaults.standardUserDefaults boolForKey:@"searchDICOMBonjour"])
		[_browser.sources removeObject:bs];
	
	if ([[_browser sourceForDatabase:_browser.database] isEqualToSource:bs])
		[_browser setDatabase:DicomDatabase.defaultDatabase];
	
	[_bonjourSources removeObjectForKey:[_bonjourSources keyForObject:bs]];
}

-(void)_analyzeVolumeAtPath:(NSString*)path {
	BOOL used = NO;
	for (BrowserSource* ibs in _browser.sources.arrangedObjects)
		if (ibs.type == BrowserSourceTypeLocal && [ibs.location hasPrefix:path])
			return; // device is somehow already listed as a source
	
	@try {
		[_browser.sources addObject:[MountedBrowserSource browserSourceForDevicePath:path description:path.lastPathComponent dictionary:nil]];
	} @catch (NSException* e) {
		N2LogExceptionWithStackTrace(e);
	}
		
	/*OSStatus err;
	 kern_return_t kr;
	 
	 FSRef ref;
	 err = FSPathMakeRef((const UInt8*)[path fileSystemRepresentation], &ref, nil);
	 if (err != noErr) return;
	 FSCatalogInfo catInfo;
	 err = FSGetCatalogInfo(&ref, kFSCatInfoVolume, &catInfo, nil, nil, nil);
	 if (err != noErr) return;
	 
	 GetVolParmsInfoBuffer gvpib;
	 HParamBlockRec hpbr;
	 hpbr.ioParam.ioNamePtr = NULL;
	 hpbr.ioParam.ioVRefNum = catInfo.volume;
	 hpbr.ioParam.ioBuffer = (Ptr)&gvpib;
	 hpbr.ioParam.ioReqCount = sizeof(gvpib);
	 err = PBHGetVolParmsSync(&hpbr);
	 if (err != noErr) return;
	 
	 NSString* bsdName = [NSString stringWithCString:(char*)gvpib.vMDeviceID];
	 NSLog(@"we are mounting %@ ||| %@", path, bsdName);
	 
	 CFDictionaryRef matchingDict = IOBSDNameMatching(kIOMasterPortDefault, 0, (const char*)gvpib.vMDeviceID);
	 io_iterator_t ioIterator = nil;
	 kr = IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict, &ioIterator);
	 if (kr != kIOReturnSuccess) return;
	 
	 io_service_t ioService;
	 while (ioService = IOIteratorNext(ioIterator)) {
	 CFTypeRef data = IORegistryEntrySearchCFProperty(ioService, kIOServicePlane, CFSTR("BSD Name"), kCFAllocatorDefault, kIORegistryIterateRecursively);
	 NSLog(@"\t%@", data);
	 io_name_t ioName;
	 IORegistryEntryGetName(ioService, ioName);
	 NSLog(@"\t\t%s", ioName);
	 
	 CFRelease(data);
	 IOObjectRelease(ioService);
	 }
	 
	 IOObjectRelease(ioIterator);*/
}

-(void)_observeVolumeNotification:(NSNotification*)notification {
	[_browser redrawSources];
	
	if ([notification.name isEqualToString:NSWorkspaceDidMountNotification]) {
		[self _analyzeVolumeAtPath:[notification.userInfo objectForKey:@"NSDevicePath"]];
	}
	
//	for (BrowserSource* bs in _browser.sources)
//		if (bs.type == BrowserSourceTypeLocal && [bs.location hasPrefix:root]) {
//			NSButton* button = [[[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 16, 16)] autorelease];
//			button.image = [NSImage imageNamed:@"iPodEjectOff.tif"];
//			button.alternateImage = [NSImage imageNamed:@"iPodEjectOn.tif"];
//			button.gradientType = NSGradientNone;
//			button.bezelStyle = 0;
//			bs.extraView = button;
//		}
			
}


-(void)_observeVolumeWillUnmountNotification:(NSNotification*)notification {
	NSString* path = [notification.userInfo objectForKey:@"NSDevicePath"];
	
	MountedBrowserSource* mbs = nil;
	for (MountedBrowserSource* ibs in _browser.sources.arrangedObjects)
		if ([ibs isKindOfClass:MountedBrowserSource.class] && [ibs.devicePath isEqualToString:path]) {
			mbs = ibs;
			break;
		}
	if (mbs) {
		if ([[_browser sourceForDatabase:_browser.database] isEqualToSource:mbs])
			[_browser setDatabase:DicomDatabase.defaultDatabase];
		[_browser.sources removeObject:mbs];
	}
}

-(NSString*)tableView:(NSTableView*)tableView toolTipForCell:(NSCell*)cell rect:(NSRectPointer)rect tableColumn:(NSTableColumn*)tc row:(NSInteger)row mouseLocation:(NSPoint)mouseLocation {
	BrowserSource* bs = [_browser sourceAtRow:row];
	NSString* tip = [bs toolTip];
	if (tip) return tip;
	return bs.location;
}

-(void)tableView:(NSTableView*)aTableView willDisplayCell:(ImageAndTextCell*)cell forTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
	cell.image = nil;
	cell.lastImage = nil;
	cell.lastImageAlternate = nil;
	cell.font = [NSFont systemFontOfSize:11];
	cell.textColor = NSColor.blackColor;
	BrowserSource* bs = [_browser sourceAtRow:row];
	[bs willDisplayCell:cell];
}


-(NSDragOperation)tableView:(NSTableView*)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
	NSInteger selectedDatabaseIndex = [_browser rowForDatabase:_browser.database];
	if (row == selectedDatabaseIndex)
		return NSDragOperationNone;
	
	if (row >= _browser.sourcesCount && _browser.database != DicomDatabase.defaultDatabase) {
		[tableView setDropRow:[_browser rowForDatabase:DicomDatabase.defaultDatabase] dropOperation:NSTableViewDropOn];
		return NSTableViewDropAbove;
	}
	
	if (row < [_browser sourcesCount]) {
		[tableView setDropRow:row dropOperation:NSTableViewDropOn];
		return NSTableViewDropAbove;
	}
	
	return NSDragOperationNone;
}

-(BOOL)tableView:(NSTableView*)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
	NSPasteboard* pb = [info draggingPasteboard];
	NSArray* xids = [NSPropertyListSerialization propertyListFromData:[pb propertyListForType:@"BrowserController.database.context.XIDs"] 
													 mutabilityOption:NSPropertyListImmutable 
															   format:NULL 
													 errorDescription:NULL];
	NSMutableArray* items = [NSMutableArray array];
	for (NSString* xid in xids)
		[items addObject:[_browser.database objectWithID:[NSManagedObject UidForXid:xid]]];
	
	NSString *filePath, *destPath;
	NSMutableArray* dicomImages = [DicomImage dicomImagesInObjects:items];
	[[NSMutableArray arrayWithArray:[dicomImages valueForKey:@"path"]] removeDuplicatedStringsInSyncWithThisArray:dicomImages]; // remove duplicated paths
	
	return [_browser initiateCopyImages:dicomImages toSource:[_browser sourceAtRow:row]];
}

-(void)tableViewSelectionDidChange:(NSNotification*)notification {
	NSInteger row = [(NSTableView*)notification.object selectedRow];
	BrowserSource* bs = [_browser sourceAtRow:row];
	[_browser setDatabaseFromSource:bs];
}

@end

@implementation DefaultBrowserSource

-(void)willDisplayCell:(ImageAndTextCell*)cell {
	cell.font = [NSFont boldSystemFontOfSize:11];
	cell.image = [NSImage imageNamed:@"osirix16x16.tif"];
}

-(NSString*)description {
	return NSLocalizedString(@"Local Default Database", nil);
}

-(NSComparisonResult)compare:(BrowserSource*)other {
	if ([self isKindOfClass:DefaultBrowserSource.class]) return NSOrderedAscending;
	else if ([other isKindOfClass:DefaultBrowserSource.class]) return NSOrderedDescending;
	return [super compare:other];
}

@end

@implementation BonjourBrowserSource

@synthesize service = _service;

-(void)dealloc {
	self.service = nil;
	[super dealloc];
}

-(void)willDisplayCell:(ImageAndTextCell*)cell {
	[super willDisplayCell:cell];
	
	NSImage* bonjour = [NSImage imageNamed:@"bonjour_whitebg.png"];
	
	NSImage* image = [[[NSImage alloc] initWithSize:cell.image.size] autorelease];
	[image lockFocus];
	[cell.image drawInRect:NSMakeRect(NSZeroPoint,cell.image.size) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
	[bonjour drawInRect:NSMakeRect(1,1,14,14) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1];
	[image unlockFocus];
	
	cell.image = image;
}

-(NSInteger)port {
	NSInteger port;
	[RemoteDicomDatabase address:self.location toHost:NULL port:&port];
	return port;
}

-(BOOL)isRemovable {
	return YES;
}

@end

@implementation MountedBrowserSource

@synthesize devicePath = _devicePath;

-(void)initiateVolumeScan {
	_database = [[DicomDatabase databaseAtPath:self.location] retain];
	[self performSelectorInBackground:@selector(volumeScanThread) withObject:nil];
}

-(void)volumeScanThread {
	NSAutoreleasePool* pool = [NSAutoreleasePool new];
	@try {
		NSThread* thread = [NSThread currentThread];
		thread.name = NSLocalizedString(@"Scanning disc...", nil);
		[ThreadsManager.defaultManager addThreadAndStart:thread];
		[_database scanAtPath:self.devicePath];
	} @catch (NSException* e) {
		N2LogExceptionWithStackTrace(e);
	} @finally {
		[pool release];
	}
}

-(DicomDatabase*)database {
	return _database;
}

+(id)browserSourceForDevicePath:(NSString*)devicePath description:(NSString*)description dictionary:(NSDictionary*)dictionary {
	BOOL scan = YES;
	NSString* path = [NSFileManager.defaultManager tmpFilePathInTmp];
	
	// does it contain an OsiriX Data folder?
	BOOL isDir;
	if ([NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:OsirixDataDirName] isDirectory:&isDir] && isDir) {
		path = devicePath;
		scan = NO;
	}
	
	MountedBrowserSource* bs = [self browserSourceForLocalPath:path description:description dictionary:dictionary];
	bs.devicePath = devicePath;
	[NSFileManager.defaultManager createDirectoryAtPath:path attributes:nil];
	
	if (scan) {
		// is there a DICOMDIR file?
		[bs initiateVolumeScan];
	}
	
	return bs;
}

-(void)dealloc {
	[_database release];
	self.devicePath = nil;
	[super dealloc];
}

-(void)willDisplayCell:(ImageAndTextCell*)cell {
	[super willDisplayCell:cell];
	
	NSImage* im = [NSWorkspace.sharedWorkspace iconForFile:self.devicePath];
	im.size = [im sizeByScalingProportionallyToSize: cell.image? cell.image.size : NSMakeSize(16,16) ];
	if (im) cell.image = im;
}

-(BOOL)isRemovable {
	return YES;
}

-(NSString*)toolTip {
	return self.devicePath;
}

@end



