//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "TestableExecutionInfo.h"

#import "OCUnitIOSAppTestQueryRunner.h"
#import "OCUnitIOSLogicTestQueryRunner.h"
#import "OCUnitOSXTestQueryRunner.h"
#import "TaskUtil.h"
#import "XcodeSubjectInfo.h"
#import "XCToolUtil.h"

@implementation TestableExecutionInfo

+ (instancetype)infoForTestable:(Testable *)testable
               xcodeSubjectInfo:(XcodeSubjectInfo *)xcodeSubjectInfo
            xcodebuildArguments:(NSArray *)xcodebuildArguments
                        testSDK:(NSString *)testSDK
                        cpuType:(cpu_type_t)cpuType
{
  TestableExecutionInfo *info = [[[TestableExecutionInfo alloc] init] autorelease];
  info.testable = testable;

  NSString *buildSettingsError = nil;
  NSDictionary *buildSettings = [[self class] testableBuildSettingsForProject:testable.projectPath
                                                                       target:testable.target
                                                                      objRoot:xcodeSubjectInfo.objRoot
                                                                      symRoot:xcodeSubjectInfo.symRoot
                                                            sharedPrecompsDir:xcodeSubjectInfo.sharedPrecompsDir
                                                               xcodeArguments:xcodebuildArguments
                                                                      testSDK:testSDK
                                                                        error:&buildSettingsError];
  
  if (buildSettings) {
    info.buildSettings = buildSettings;
  } else {
    info.buildSettingsError = buildSettingsError;
    return info;
  }

  NSString *otestQueryError = nil;
  NSArray *testCases = [[self class] queryTestCasesWithBuildSettings:info.buildSettings
                                                             cpuType:cpuType
                                                               error:&otestQueryError];
  if (testCases) {
    info.testCases = testCases;
  } else {
    info.testCasesQueryError = otestQueryError;
  }

  // In Xcode, you can optionally include variables in your args or environment
  // variables.  i.e. "$(ARCHS)" gets transformed into "armv7".
  if (testable.macroExpansionProjectPath != nil) {
    info.expandedArguments = [self argumentsWithMacrosExpanded:testable.arguments
                                             fromBuildSettings:info.buildSettings];
    info.expandedEnvironment = [self enviornmentWithMacrosExpanded:testable.environment
                                    fromBuildSettings:info.buildSettings];
  } else {
    info.expandedArguments = testable.arguments;
    info.expandedEnvironment = testable.environment;
  }

  return info;
}

+ (NSDictionary *)testableBuildSettingsForProject:(NSString *)projectPath
                                           target:(NSString *)target
                                          objRoot:(NSString *)objRoot
                                          symRoot:(NSString *)symRoot
                                sharedPrecompsDir:(NSString *)sharedPrecompsDir
                                   xcodeArguments:(NSArray *)xcodeArguments
                                          testSDK:(NSString *)testSDK
                                            error:(NSString **)error
{
  // Collect build settings for this test target.
  NSTask *settingsTask = CreateTaskInSameProcessGroup();
  [settingsTask setLaunchPath:[XcodeDeveloperDirPath() stringByAppendingPathComponent:@"usr/bin/xcodebuild"]];

  if (testSDK) {
    // If we were given a test sdk, then force that.  Otherwise, xcodebuild will
    // default to the SDK set in the project/target.
    xcodeArguments = ArgumentListByOverriding(xcodeArguments, @"-sdk", testSDK);
  }

  [settingsTask setArguments:[xcodeArguments arrayByAddingObjectsFromArray:@[
                                                                             @"-project", projectPath,
                                                                             @"-target", target,
                                                                             [NSString stringWithFormat:@"OBJROOT=%@", objRoot],
                                                                             [NSString stringWithFormat:@"SYMROOT=%@", symRoot],
                                                                             [NSString stringWithFormat:@"SHARED_PRECOMPS_DIR=%@", sharedPrecompsDir],
                                                                             @"-showBuildSettings",
                                                                             ]]];

  [settingsTask setEnvironment:@{
                                 @"DYLD_INSERT_LIBRARIES" : [XCToolLibPath() stringByAppendingPathComponent:@"xcodebuild-fastsettings-shim.dylib"],
                                 @"SHOW_ONLY_BUILD_SETTINGS_FOR_TARGET" : target,
                                 }];

  NSDictionary *result = LaunchTaskAndCaptureOutput(settingsTask,
                                                    [NSString stringWithFormat:@"running xcodebuild -showBuildSettings for '%@' target", target]);
  [settingsTask release];
  settingsTask = nil;

  NSDictionary *allSettings = BuildSettingsFromOutput(result[@"stdout"]);

  if ([allSettings count] > 1) {
    *error = @"Should only have build settings for a single target.";
    return nil;
  }

  if ([allSettings count] == 0) {
    *error = [NSString stringWithFormat:@"Could not get build settings. Output of 'xcodebuid -showBuildSettings' was:\n"
                                        @"(stdout): %@\n"
                                        @"(stderr): %@\n",
              result[@"stdout"],
              result[@"stderr"]];
    return nil;
  }

  if (!allSettings[target]) {
    *error = [NSString stringWithFormat:@"Should have found build settings for target '%@'", target];
    return nil;
  }
  
  return allSettings[target];
}

/**
 * Use otest-query-[ios|osx] to get a list of all SenTestCase classes in the
 * test bundle.
 */
+ (NSArray *)queryTestCasesWithBuildSettings:(NSDictionary *)testableBuildSettings
                                     cpuType:(cpu_type_t)cpuType
                                       error:(NSString **)error
{
  NSString *sdkName = testableBuildSettings[@"SDK_NAME"];
  BOOL hasTestHost = (testableBuildSettings[@"TEST_HOST"] != nil);
  Class runnerClass = {0};
  if ([sdkName hasPrefix:@"iphonesimulator"]) {
    if (hasTestHost) {
      runnerClass = [OCUnitIOSAppTestQueryRunner class];
    } else {
      runnerClass = [OCUnitIOSLogicTestQueryRunner class];
    }
  } else if ([sdkName hasPrefix:@"macosx"]) {
    runnerClass = [OCUnitOSXTestQueryRunner class];
  } else if ([sdkName hasPrefix:@"iphoneos"]) {
    // We can't run tests on device yet, but we must return a test list here or
    // we'll never get far enough to run OCUnitIOSDeviceTestRunner.
    return @[@"Placeholder/ForDeviceTests"];
  } else {
    NSAssert(NO, @"Unexpected SDK: %@", sdkName);
    abort();
  }
  OCUnitTestQueryRunner *runner = [[[runnerClass alloc] initWithBuildSettings:testableBuildSettings
                                                                  withCpuType:cpuType] autorelease];
  return [runner runQueryWithError:error];
}

+ (NSString *)stringWithMacrosExpanded:(NSString *)str
                     fromBuildSettings:(NSDictionary *)settings
{
  NSMutableString *result = [NSMutableString stringWithString:str];

  [settings enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *val, BOOL *stop){
    NSString *macroStr = [[NSString alloc] initWithFormat:@"$(%@)", key];
    [result replaceOccurrencesOfString:macroStr
                            withString:val
                               options:0
                                 range:NSMakeRange(0, [result length])];
    [macroStr release];
  }];

  return result;
}

+ (NSArray *)argumentsWithMacrosExpanded:(NSArray *)arr
                       fromBuildSettings:(NSDictionary *)settings
{
  NSMutableArray *result = [NSMutableArray arrayWithCapacity:[arr count]];

  for (NSString *str in arr) {
    [result addObject:[[self class] stringWithMacrosExpanded:str
                                           fromBuildSettings:settings]];
  }

  return result;
}

+ (NSDictionary *)enviornmentWithMacrosExpanded:(NSDictionary *)dict
                              fromBuildSettings:(NSDictionary *)settings
{
  NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[dict count]];

  for (NSString *key in [dict allKeys]) {
    NSString *keyExpanded = [[self class] stringWithMacrosExpanded:key
                                                 fromBuildSettings:settings];
    NSString *valExpanded = [[self class] stringWithMacrosExpanded:dict[key]
                                                 fromBuildSettings:settings];
    result[keyExpanded] = valExpanded;
  }

  return result;
}

@end
