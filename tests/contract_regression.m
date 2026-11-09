// Strict JSON, site policy and backup container contracts. Foundation only: no UIKit, no network.
#import <Foundation/Foundation.h>
#import "FDMJSON.h"
#import "FDMPolicy.h"
#import "FDMBackup.h"
#import "FDMCommon.h"
#import "FDMIntent.h"

static void FDMCheck(BOOL condition, NSString *message) {
    if (!condition) [NSException raise:@"FDMContractRegression" format:@"%@", message];
}

static NSData *FDMData(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static void FDMTestJSON(void) {
    NSError *error = nil;
    // Duplicate object members must be refused: last-wins would silently drop a user rule.
    FDMCheck(FDMJSONParseData(FDMData(@"{ \"a\": 1, \"a\": 2 }"), &error) == nil, @"duplicate object key rejected");
    FDMCheck(error != nil, @"duplicate key reports a reason");
    FDMCheck(FDMJSONParseData(FDMData(@"[1, 2, 3]"), &error) != nil, @"array accepted");
    FDMCheck(FDMJSONParseData(FDMData(@"{ \"n\": NaN }"), &error) == nil, @"NaN rejected");
    FDMCheck(FDMJSONParseData(FDMData(@"{ \"n\": Infinity }"), &error) == nil, @"Infinity rejected");
    FDMCheck(FDMJSONParseData(FDMData(@"{ \"n\": 01 }"), &error) == nil, @"leading zero rejected");
    FDMCheck(FDMJSONParseData(FDMData(@"{ \"n\": 1. }"), &error) == nil, @"bare fraction rejected");
    FDMCheck(FDMJSONParseData(FDMData(@"{} trailing"), &error) == nil, @"trailing content rejected");
    FDMCheck(FDMJSONParseData(FDMData(@"\"unterminated"), &error) == nil, @"unterminated string rejected");
    // Bytes that are not valid UTF-8 must be refused, not silently replaced.
    const unsigned char invalid[] = {'{', ' ', '"', 'n', '"', ':', ' ', '"', 0xFF, 0xFE, '"', ' ', '}'};
    FDMCheck(FDMJSONParseData([NSData dataWithBytes:invalid length:sizeof(invalid)], &error) == nil, @"invalid UTF-8 rejected");

    // Depth bound: 40 nested arrays exceed the 32-level contract.
    NSMutableString *deep = [NSMutableString string];
    for (NSUInteger i = 0; i < 40; i++) [deep appendString:@"["];
    for (NSUInteger i = 0; i < 40; i++) [deep appendString:@"]"];
    FDMCheck(FDMJSONParseData(FDMData(deep), &error) == nil, @"over-deep JSON rejected");

    // Surrogate pairs survive round-trip; lone surrogates do not.
    id parsed = FDMJSONParseData(FDMData(@"{ \"emoji\": \"\\ud83d\\ude00\" }"), &error);
    FDMCheck([parsed[@"emoji"] isEqual:@"😀"], @"surrogate pair decoded");
    FDMCheck(FDMJSONParseData(FDMData(@"{ \"bad\": \"\\ud83d\" }"), &error) == nil, @"lone surrogate rejected");

    // Integers stay integral so a count never aliases a boolean.
    id numbers = FDMJSONParseData(FDMData(@"{ \"i\": 9007199254740991, \"f\": 1.5, \"t\": true }"), &error);
    FDMCheck([numbers[@"i"] longLongValue] == 9007199254740991LL, @"large integer preserved");
    unsigned long long value = 0;
    FDMCheck(FDMJSONNonNegativeInteger(numbers[@"i"], 9007199254740991ULL, &value) && value == 9007199254740991ULL, @"integer accepted at bound");
    FDMCheck(!FDMJSONNonNegativeInteger(numbers[@"t"], 100, &value), @"boolean is not an integer");
    FDMCheck(!FDMJSONNonNegativeInteger(numbers[@"f"], 100, &value), @"fraction is not an integer");
    FDMCheck(!FDMJSONNonNegativeInteger(@(-1), 100, &value), @"negative rejected");

    // Canonical encoding is key-order stable so a hash of the bytes is meaningful.
    NSData *left = FDMJSONCanonicalData(@{@"b": @2, @"a": @1}, &error);
    NSData *right = FDMJSONCanonicalData(@{@"a": @1, @"b": @2}, &error);
    FDMCheck([left isEqualToData:right], @"canonical output is order independent");
    NSData *nonFinite = FDMJSONCanonicalData(@{@"n": @(NAN)}, &error);
    FDMCheck(nonFinite == nil, @"non-finite number cannot be encoded");
    printf("json contract passed\n");
}

static void FDMTestOrigin(void) {
    FDMCheck([FDMNormalizedOrigin(@"https://Example.COM/path") isEqual:@"https://example.com:443"], @"default https port normalized");
    FDMCheck([FDMNormalizedOrigin(@"http://example.com") isEqual:@"http://example.com:80"], @"default http port normalized");
    FDMCheck([FDMNormalizedOrigin(@"https://example.com:8443/x") isEqual:@"https://example.com:8443"], @"explicit port kept");
    FDMCheck([FDMNormalizedOrigin(@"http://example.com:8443") isEqual:@"http://example.com:8443"], @"http non-default port kept");
    // scheme, port and subdomain are distinct origins; no suffix guessing.
    FDMCheck(![FDMNormalizedOrigin(@"https://example.com") isEqual:FDMNormalizedOrigin(@"http://example.com")], @"scheme separates origins");
    FDMCheck(![FDMNormalizedOrigin(@"https://a.example.com") isEqual:FDMNormalizedOrigin(@"https://example.com")], @"subdomain is a distinct origin");
    FDMCheck(![FDMNormalizedOrigin(@"https://example.com:8443") isEqual:FDMNormalizedOrigin(@"https://example.com")], @"port separates origins");
    FDMCheck(FDMNormalizedOrigin(@"file:///etc/passwd") == nil, @"file scheme rejected");
    FDMCheck(FDMNormalizedOrigin(@"https://user:pw@example.com") == nil, @"userinfo rejected");
    FDMCheck(FDMNormalizedOrigin(@"https:///nohost") == nil, @"missing host rejected");
    FDMCheck(FDMNormalizedOrigin(@"https://example.com:99999") == nil, @"out-of-range port rejected");
    FDMCheck(FDMNormalizedOrigin(@"javascript:alert(1)") == nil, @"non-http scheme rejected");
    printf("origin normalization passed\n");
}

static void FDMTestPolicyValidation(void) {
    NSError *error = nil;
    NSDictionary *valid = @{@"schemaVersion": @1, @"revision": @3, @"origins": @{
        @"https://news.example:443": @{@"preferredContentMode": @"desktop", @"pageZoom": @1.15,
                                        @"camera": @"deny", @"customUserAgent": @"Custom/1.0"}}};
    NSDictionary *document = FDMSitePolicyValidateDocument(valid, &error);
    FDMCheck(document && [document[@"revision"] isEqual:@3], @"valid policy accepted");
    FDMCheck([document[@"origins"][@"https://news.example:443"][@"pageZoom"] isEqual:@1.15], @"zoom preserved");

    // A different spelling that normalizes onto an existing key must be refused, not last-wins.
    NSDictionary *collision = @{@"schemaVersion": @1, @"revision": @0, @"origins": @{
        @"https://a.example": @{@"reader": @"auto"}, @"https://A.EXAMPLE:443": @{@"reader": @"off"}}};
    FDMCheck(FDMSitePolicyValidateDocument(collision, &error) == nil, @"normalized origin collision rejected");

    NSDictionary *duplicateValue = @{@"schemaVersion": @1, @"revision": @0, @"origins": @{
        @"https://a.example": @{@"pageZoom": @1.0}}};
    FDMCheck(FDMSitePolicyValidateDocument(duplicateValue, &error) != nil, @"single entry accepted");
    NSDictionary *badZoom = @{@"schemaVersion": @1, @"revision": @0, @"origins": @{
        @"https://a.example": @{@"pageZoom": @4.0}}};
    FDMCheck(FDMSitePolicyValidateDocument(badZoom, &error) == nil, @"out-of-range zoom rejected");
    NSDictionary *fractionalRevision = @{@"schemaVersion": @1, @"revision": @1.5, @"origins": @{}};
    FDMCheck(FDMSitePolicyValidateDocument(fractionalRevision, &error) == nil, @"fractional revision rejected");
    NSDictionary *booleanRevision = @{@"schemaVersion": @1, @"revision": @YES, @"origins": @{}};
    FDMCheck(FDMSitePolicyValidateDocument(booleanRevision, &error) == nil, @"boolean revision rejected");
    NSDictionary *unknownField = @{@"schemaVersion": @1, @"revision": @0, @"origins": @{
        @"https://a.example": @{@"unknownSetting": @"x"}}};
    FDMCheck(FDMSitePolicyValidateDocument(unknownField, &error) == nil, @"unknown entry field rejected");
    NSDictionary *badVersion = @{@"schemaVersion": @2, @"revision": @0, @"origins": @{}};
    FDMCheck(FDMSitePolicyValidateDocument(badVersion, &error) == nil, @"unsupported schema version rejected");

    // Only customUserAgent accepts a null sentinel, which means "remove the override".
    NSDictionary *nullUA = FDMSitePolicyValidateEntry(@{@"customUserAgent": NSNull.null}, &error);
    FDMCheck(nullUA && nullUA[@"customUserAgent"] == NSNull.null, @"null UA override preserved");
    FDMCheck(FDMSitePolicyValidateEntry(@{@"reader": NSNull.null}, &error) == nil, @"null on other fields rejected");
    // "inherit" is dropped rather than stored as a literal value.
    NSDictionary *inherit = FDMSitePolicyValidateEntry(@{@"reader": @"inherit", @"camera": @"deny"}, &error);
    FDMCheck(inherit.count == 1 && !inherit[@"reader"], @"inherit is not stored");

    // Resolution: a missing override falls back to the global baseline, including a null baseline.
    NSDictionary *entry = @{@"pageZoom": @1.5};
    NSDictionary *global = @{FDMPolicyUserAgent: @"GlobalUA"};
    FDMCheck([FDMPolicyEffectiveValue(entry, FDMPolicyUserAgent, global) isEqual:@"GlobalUA"], @"global UA inherited");
    FDMCheck([FDMPolicyEffectiveValue(entry, FDMPolicyPageZoom, global) isEqual:@"1.5"], @"site zoom wins");
    FDMCheck(FDMPolicyEffectiveValue(entry, FDMPolicyReader, @{}) == nil, @"unset field resolves to nil");
    NSArray *overridden = FDMPolicyOverriddenFields(entry);
    FDMCheck(overridden.count == 1 && [overridden.firstObject isEqual:FDMPolicyPageZoom], @"overridden list is exact");
    printf("policy validation passed\n");
}

static void FDMTestBackupContainer(void) {
    NSError *error = nil;
    NSData *policyPayload = FDMJSONCanonicalData(@{@"schemaVersion": @1, @"revision": @2, @"origins": @{}}, &error);
    FDMBackupCategory *category = [FDMBackupCategory category:FDMBackupCategorySitePolicies payload:policyPayload itemCount:0];
    NSData *encoded = FDMBackupEncode(@[category], @"v20", &error);
    FDMCheck(encoded.length > 0, @"container encoded");
    FDMBackupContainer *decoded = FDMBackupDecode(encoded, &error);
    FDMCheck(decoded && decoded.categories.count == 1, @"container round-trips");
    FDMCheck([decoded.categories[FDMBackupCategorySitePolicies].payload isEqualToData:policyPayload], @"payload bytes preserved");
    FDMCheck([decoded.producerVersion isEqual:@"v20"], @"producer version preserved");

    // Tampering with the payload breaks the declared hash. The payload is base64, so change one
    // character of it rather than the container's own text.
    NSString *text = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    NSRange payloadRange = [text rangeOfString:@"\"dataBase64\":\""];
    FDMCheck(payloadRange.location != NSNotFound, @"container carries an encoded payload");
    NSUInteger payloadStart = NSMaxRange(payloadRange);
    FDMCheck(payloadStart < text.length, @"payload is not empty");
    unichar original = [text characterAtIndex:payloadStart];
    unichar replacement = original == 'A' ? 'B' : 'A';
    NSString *tampered = [text stringByReplacingCharactersInRange:NSMakeRange(payloadStart, 1)
                                                      withString:[NSString stringWithCharacters:&replacement length:1]];
    FDMCheck(FDMBackupDecode(FDMData(tampered), &error) == nil, @"tampered payload rejected by hash");

    // Duplicate categories, unknown top-level fields and unsupported versions are refused.
    NSString *duplicate = [text stringByReplacingOccurrencesOfString:@"\"categories\":["
                                                          withString:@"\"categories\":[{\"id\":\"sitePolicies\",\"schemaVersion\":1,\"encoding\":\"json-utf8-base64\",\"itemCount\":0,\"byteLength\":0,\"sha256\":\"0000000000000000000000000000000000000000000000000000000000000000\",\"dataBase64\":\"\"},"];
    FDMCheck(FDMBackupDecode(FDMData(duplicate), &error) == nil, @"duplicate category rejected");
    NSString *unknownTop = [text stringByReplacingOccurrencesOfString:@"\"format\":" withString:@"\"extra\":1,\"format\":"];
    FDMCheck(FDMBackupDecode(FDMData(unknownTop), &error) == nil, @"unknown top-level field rejected");
    NSString *badFormat = [text stringByReplacingOccurrencesOfString:@"ios-browser-backup" withString:@"other-backup"];
    FDMCheck(FDMBackupDecode(FDMData(badFormat), &error) == nil, @"foreign file rejected");
    NSString *badVersion = [text stringByReplacingOccurrencesOfString:@"\"schemaVersion\":1,\"backupID\"" withString:@"\"schemaVersion\":9,\"backupID\""];
    FDMCheck(FDMBackupDecode(FDMData(badVersion), &error) == nil, @"unsupported container version rejected");
    // Duplicate JSON keys inside the container are refused by the strict parser.
    NSString *duplicateKey = [text stringByReplacingOccurrencesOfString:@"\"format\":\"ios-browser-backup\""
                                                             withString:@"\"format\":\"ios-browser-backup\",\"format\":\"ios-browser-backup\""];
    FDMCheck(FDMBackupDecode(FDMData(duplicateKey), &error) == nil, @"duplicate container key rejected");
    // A declared byteLength that disagrees with the decoded bytes must be refused.
    NSString *badLength = [text stringByReplacingOccurrencesOfString:@"\"byteLength\":"
                                                          withString:@"\"byteLength\":1"];
    FDMCheck(FDMBackupDecode(FDMData(badLength), &error) == nil, @"length mismatch rejected");
    // Base64 that is not valid must be refused before any decode budget is spent.
    NSString *badBase64 = [text stringByReplacingOccurrencesOfString:@"\"dataBase64\":\""
                                                          withString:@"\"dataBase64\":\"!!!!"];
    FDMCheck(FDMBackupDecode(FDMData(badBase64), &error) == nil, @"invalid base64 rejected");
    // An unknown but well-formed category is reported, not applied.
    NSString *unknownCategory = [text stringByReplacingOccurrencesOfString:@"\"id\":\"sitePolicies\""
                                                                withString:@"\"id\":\"unknownCategory\""];
    FDMBackupContainer *unknown = FDMBackupDecode(FDMData(unknownCategory), &error);
    FDMCheck(unknown && [unknown.unsupportedCategories containsObject:@"unknownCategory"], @"unknown category reported as unsupported");

    FDMCheck(FDMBackupCategorySelectedByDefault(FDMBackupCategoryScripts) == NO, @"scripts are opt-in");
    FDMCheck(FDMBackupCategorySelectedByDefault(FDMBackupCategoryBookmarks) == YES, @"bookmarks default on");
    printf("backup container passed\n");
}

static void FDMTestIntentPolicy(void) {
    NSError *error = nil;
    NSMutableURLRequest *same = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://a.example/file.zip"]];
    NSMutableURLRequest *sameHop = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://a.example/other.zip"]];
    FDMCheck(FDMRedirectRefusal(same, sameHop) == nil, @"same-origin redirect allowed");

    NSMutableURLRequest *crossOrigin = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://b.example/file.zip"]];
    FDMCheck(FDMRedirectRefusal(same, crossOrigin) != nil, @"cross-origin redirect refused by default");

    NSMutableURLRequest *credentialed = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://a.example/file.zip"]];
    [credentialed setValue:@"Bearer secret" forHTTPHeaderField:@"Authorization"];
    FDMCheck(FDMRedirectRefusal(credentialed, crossOrigin) != nil, @"credentialed cross-origin refused");

    NSMutableURLRequest *https = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://a.example/file.zip"]];
    NSMutableURLRequest *downgrade = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://a.example/file.zip"]];
    FDMCheck(FDMRedirectRefusal(https, downgrade) != nil, @"https to http downgrade refused");

    FDMCheck(FDMIsSecretHeader(@"Authorization") && FDMIsSecretHeader(@"cookie"), @"secret headers recognized");
    FDMCheck(!FDMIsSecretHeader(@"Accept"), @"ordinary header not secret");
    NSString *names = FDMRedactedHeaderNames(@{@"Authorization": @"secret", @"Accept": @"*/*"});
    FDMCheck(![names containsString:@"secret"], @"header values never appear in the log string");
    FDMCheck([names containsString:@"Authorization=<redacted>"], @"secret header marked");

    FDMCheck([FDMTransportName(FDMTransportWebKitDownload) isEqual:@"webKitDownload"], @"transport naming stable");
    FDMCheck([FDMSchedulerStatusName(FDMSchedulerNeedsContext) isEqual:@"需要重新发起"], @"scheduler naming stable");
    (void)error;
    printf("intent and redirect policy passed\n");
}

void FDMRunContractRegression(void) {
    FDMTestJSON();
    FDMTestOrigin();
    FDMTestPolicyValidation();
    FDMTestBackupContainer();
    FDMTestIntentPolicy();
    printf("contract regression suite passed\n");
}
