#import "FDMJSON.h"
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>
#import <limits.h>

NSUInteger const FDMJSONMaxDepth = 32;
NSUInteger const FDMJSONMaxBytes = 32 * 1024 * 1024;

typedef struct {
    const unichar *chars;
    NSUInteger length;
    NSUInteger index;
    NSUInteger depth;
    NSUInteger maxDepth;
} FDMScanner;

static NSError *FDMJSONError(NSString *message) {
    return [NSError errorWithDomain:@"FocusDM.JSON" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static void FDMScanWhitespace(FDMScanner *scanner) {
    while (scanner->index < scanner->length) {
        unichar c = scanner->chars[scanner->index];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') scanner->index++;
        else break;
    }
}

static BOOL FDMScanLiteral(FDMScanner *scanner, NSString *literal) {
    if (scanner->length - scanner->index < literal.length) return NO;
    for (NSUInteger i = 0; i < literal.length; i++) {
        if (scanner->chars[scanner->index + i] != [literal characterAtIndex:i]) return NO;
    }
    scanner->index += literal.length;
    return YES;
}

static NSNumber *FDMScanNumber(FDMScanner *scanner) {
    NSUInteger start = scanner->index;
    if (scanner->index < scanner->length && scanner->chars[scanner->index] == '-') scanner->index++;
    NSUInteger integerStart = scanner->index;
    NSUInteger digits = 0;
    while (scanner->index < scanner->length && scanner->chars[scanner->index] >= '0' && scanner->chars[scanner->index] <= '9') {
        scanner->index++;
        digits++;
    }
    if (!digits) return nil;
    // JSON forbids a leading zero, except the single digit 0 itself.
    if (digits > 1 && scanner->chars[integerStart] == '0') return nil;
    BOOL fractional = NO;
    if (scanner->index < scanner->length && scanner->chars[scanner->index] == '.') {
        fractional = YES;
        scanner->index++;
        NSUInteger fraction = 0;
        while (scanner->index < scanner->length && scanner->chars[scanner->index] >= '0' && scanner->chars[scanner->index] <= '9') {
            scanner->index++;
            fraction++;
        }
        if (!fraction) return nil;
    }
    if (scanner->index < scanner->length && (scanner->chars[scanner->index] == 'e' || scanner->chars[scanner->index] == 'E')) {
        fractional = YES;
        scanner->index++;
        if (scanner->index < scanner->length && (scanner->chars[scanner->index] == '+' || scanner->chars[scanner->index] == '-')) scanner->index++;
        NSUInteger exponent = 0;
        while (scanner->index < scanner->length && scanner->chars[scanner->index] >= '0' && scanner->chars[scanner->index] <= '9') {
            scanner->index++;
            exponent++;
        }
        if (!exponent) return nil;
    }
    NSString *text = [NSString stringWithCharacters:scanner->chars + start length:scanner->index - start];
    if (!fractional) {
        BOOL negative = scanner->chars[start] == '-';
        unsigned long long integer = 0;
        for (NSUInteger i = integerStart; i < integerStart + digits; i++) {
            unsigned digit = scanner->chars[i] - '0';
            if (integer > (ULLONG_MAX - digit) / 10) return nil;
            integer = integer * 10 + digit;
        }
        if (negative) {
            if (integer > (unsigned long long)LLONG_MAX + 1ULL) return nil;
            if (integer == (unsigned long long)LLONG_MAX + 1ULL) return @(LLONG_MIN);
            return @(-(long long)integer);
        }
        return @(integer);
    }
    NSDecimalNumber *number = [NSDecimalNumber decimalNumberWithString:text locale:@{NSLocaleDecimalSeparator: @"."}];
    if ([number isEqual:NSDecimalNumber.notANumber] || !isfinite(number.doubleValue)) return nil;
    return number;
}

static BOOL FDMReadHex4(FDMScanner *scanner, uint32_t *out);

static BOOL FDMAppendCodePoint(NSMutableString *result, uint32_t code) {
    if (code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return NO;
    if (code <= 0xFFFF) { [result appendFormat:@"%C", (unichar)code]; return YES; }
    uint32_t value = code - 0x10000;
    unichar pair[2] = {(unichar)(0xD800 + (value >> 10)), (unichar)(0xDC00 + (value & 0x3FF))};
    [result appendString:[NSString stringWithCharacters:pair length:2]];
    return YES;
}

static NSString *FDMScanString(FDMScanner *scanner) {
    if (scanner->index >= scanner->length || scanner->chars[scanner->index] != '"') return nil;
    scanner->index++;
    NSMutableString *result = [NSMutableString string];
    while (scanner->index < scanner->length) {
        unichar c = scanner->chars[scanner->index++];
        if (c == '"') return result;
        if (c < 0x20) return nil;
        if (c != '\\') {
            if (c >= 0xD800 && c <= 0xDBFF) {
                if (scanner->index >= scanner->length) return nil;
                unichar low = scanner->chars[scanner->index++];
                if (low < 0xDC00 || low > 0xDFFF) return nil;
                unichar pair[2] = {c, low}; [result appendString:[NSString stringWithCharacters:pair length:2]];
            } else if (c >= 0xDC00 && c <= 0xDFFF) return nil;
            else [result appendString:[NSString stringWithCharacters:&c length:1]];
            continue;
        }
        if (scanner->index >= scanner->length) return nil;
        unichar escape = scanner->chars[scanner->index++];
        switch (escape) {
            case '"': [result appendString:@"\""]; break;
            case '\\': [result appendString:@"\\"]; break;
            case '/': [result appendString:@"/"]; break;
            case 'b': [result appendString:@"\b"]; break;
            case 'f': [result appendString:@"\f"]; break;
            case 'n': [result appendString:@"\n"]; break;
            case 'r': [result appendString:@"\r"]; break;
            case 't': [result appendString:@"\t"]; break;
            case 'u': {
                uint32_t unit = 0;
                if (!FDMReadHex4(scanner, &unit)) return nil;
                if (unit >= 0xD800 && unit <= 0xDBFF) {
                    if (scanner->index + 2 > scanner->length || scanner->chars[scanner->index] != '\\' || scanner->chars[scanner->index + 1] != 'u') return nil;
                    scanner->index += 2;
                    uint32_t low = 0;
                    if (!FDMReadHex4(scanner, &low)) return nil;
                    if (low < 0xDC00 || low > 0xDFFF) return nil;
                    uint32_t combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                    if (!FDMAppendCodePoint(result, combined)) return nil;
                } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
                    return nil;  // lone low surrogate
                } else {
                    [result appendFormat:@"%C", (unichar)unit];
                }
                break;
            }
            default: return nil;
        }
    }
    return nil;
}

static BOOL FDMReadHex4(FDMScanner *scanner, uint32_t *out) {
    if (scanner->index + 4 > scanner->length) return NO;
    uint32_t unit = 0;
    for (NSUInteger i = 0; i < 4; i++) {
        unichar digit = scanner->chars[scanner->index++];
        unit <<= 4;
        if (digit >= '0' && digit <= '9') unit |= (uint32_t)(digit - '0');
        else if (digit >= 'a' && digit <= 'f') unit |= (uint32_t)(digit - 'a' + 10);
        else if (digit >= 'A' && digit <= 'F') unit |= (uint32_t)(digit - 'A' + 10);
        else return NO;
    }
    *out = unit;
    return YES;
}

static id FDMScanValue(FDMScanner *scanner, NSError **error);

static NSArray *FDMScanArray(FDMScanner *scanner, NSError **error) {
    scanner->index++;  // '['
    NSMutableArray *result = [NSMutableArray array];
    FDMScanWhitespace(scanner);
    if (scanner->index < scanner->length && scanner->chars[scanner->index] == ']') { scanner->index++; return [result copy]; }
    while (YES) {
        id element = FDMScanValue(scanner, error);
        if (!element) return nil;
        [result addObject:element];
        FDMScanWhitespace(scanner);
        if (scanner->index >= scanner->length) { if (error) *error = FDMJSONError(@"数组未闭合"); return nil; }
        unichar c = scanner->chars[scanner->index++];
        if (c == ']') return [result copy];
        if (c != ',') { if (error) *error = FDMJSONError(@"数组分隔符无效"); return nil; }
        FDMScanWhitespace(scanner);
    }
}

static NSDictionary *FDMScanObject(FDMScanner *scanner, NSError **error) {
    scanner->index++;  // '{'
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    FDMScanWhitespace(scanner);
    if (scanner->index < scanner->length && scanner->chars[scanner->index] == '}') { scanner->index++; return [result copy]; }
    while (YES) {
        FDMScanWhitespace(scanner);
        NSString *key = FDMScanString(scanner);
        if (!key) { if (error) *error = FDMJSONError(@"对象键名无效"); return nil; }
        if ([keys containsObject:key]) { if (error) *error = FDMJSONError([NSString stringWithFormat:@"对象存在重复键：%@", key]); return nil; }
        [keys addObject:key];
        FDMScanWhitespace(scanner);
        if (scanner->index >= scanner->length || scanner->chars[scanner->index] != ':') { if (error) *error = FDMJSONError(@"对象缺少冒号"); return nil; }
        scanner->index++;
        id value = FDMScanValue(scanner, error);
        if (!value) return nil;
        result[key] = value;
        FDMScanWhitespace(scanner);
        if (scanner->index >= scanner->length) { if (error) *error = FDMJSONError(@"对象未闭合"); return nil; }
        unichar c = scanner->chars[scanner->index++];
        if (c == '}') return [result copy];
        if (c != ',') { if (error) *error = FDMJSONError(@"对象分隔符无效"); return nil; }
    }
}

static id FDMScanValue(FDMScanner *scanner, NSError **error) {
    FDMScanWhitespace(scanner);
    if (scanner->index >= scanner->length) { if (error) *error = FDMJSONError(@"JSON 内容为空或提前结束"); return nil; }
    unichar c = scanner->chars[scanner->index];
    if (c == '{' || c == '[') {
        if (scanner->depth >= scanner->maxDepth) { if (error) *error = FDMJSONError(@"JSON 嵌套层级超出上限"); return nil; }
        scanner->depth++;
        id value = c == '{' ? (id)FDMScanObject(scanner, error) : (id)FDMScanArray(scanner, error);
        scanner->depth--;
        return value;
    }
    if (c == '"') {
        NSString *string = FDMScanString(scanner);
        if (!string) { if (error) *error = FDMJSONError(@"字符串无效"); return nil; }
        return string;
    }
    if (c == 't') { if (FDMScanLiteral(scanner, @"true")) return @YES; if (error) *error = FDMJSONError(@"字面量无效"); return nil; }
    if (c == 'f') { if (FDMScanLiteral(scanner, @"false")) return @NO; if (error) *error = FDMJSONError(@"字面量无效"); return nil; }
    if (c == 'n') { if (FDMScanLiteral(scanner, @"null")) return NSNull.null; if (error) *error = FDMJSONError(@"字面量无效"); return nil; }
    if (c == '-' || (c >= '0' && c <= '9')) {
        NSNumber *number = FDMScanNumber(scanner);
        if (!number) { if (error) *error = FDMJSONError(@"数字格式无效"); return nil; }
        return number;
    }
    if (error) *error = FDMJSONError(@"JSON 含不支持的字面量（不接受 NaN/Infinity）");
    return nil;
}

id FDMJSONParseDataBounded(NSData *data, NSUInteger maxDepth, NSUInteger maxBytes, NSError **error) {
    if (![data isKindOfClass:NSData.class]) { if (error) *error = FDMJSONError(@"输入不是字节数据"); return nil; }
    if (data.length > maxBytes) { if (error) *error = FDMJSONError(@"JSON 字节数超出上限"); return nil; }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { if (error) *error = FDMJSONError(@"JSON 不是合法的 UTF-8"); return nil; }
    if (text.length > maxBytes) { if (error) *error = FDMJSONError(@"JSON 字符数超出上限"); return nil; }
    NSMutableData *buffer = [NSMutableData dataWithLength:MAX((NSUInteger)1, text.length) * sizeof(unichar)];
    [text getCharacters:buffer.mutableBytes range:NSMakeRange(0, text.length)];
    FDMScanner scanner = {.chars = buffer.bytes, .length = text.length, .index = 0, .depth = 0, .maxDepth = maxDepth};
    id value = FDMScanValue(&scanner, error);
    if (!value) return nil;
    FDMScanWhitespace(&scanner);
    if (scanner.index != scanner.length) { if (error) *error = FDMJSONError(@"JSON 结尾存在多余内容"); return nil; }
    return value;
}

id FDMJSONParseData(NSData *data, NSError **error) {
    return FDMJSONParseDataBounded(data, FDMJSONMaxDepth, FDMJSONMaxBytes, error);
}

static BOOL FDMAppendCanonical(NSMutableString *out, id value, NSError **error) {
    if ([value isKindOfClass:NSString.class]) {
        [out appendString:@"\""];
        for (NSUInteger i = 0; i < [value length]; i++) {
            unichar c = [value characterAtIndex:i];
            switch (c) {
                case '"': [out appendString:@"\\\""]; break;
                case '\\': [out appendString:@"\\\\"]; break;
                case '\n': [out appendString:@"\\n"]; break;
                case '\r': [out appendString:@"\\r"]; break;
                case '\t': [out appendString:@"\\t"]; break;
                case '\b': [out appendString:@"\\b"]; break;
                case '\f': [out appendString:@"\\f"]; break;
                default:
                    if (c < 0x20) [out appendFormat:@"\\u%04x", (unsigned)c];
                    else [out appendFormat:@"%C", c];
            }
        }
        [out appendString:@"\""];
        return YES;
    }
    if ([value isKindOfClass:NSNumber.class]) {
        NSNumber *number = value;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) { [out appendString:number.boolValue ? @"true" : @"false"]; return YES; }
        double raw = number.doubleValue;
        if (!isfinite(raw)) { if (error) *error = FDMJSONError(@"数值不是有限数"); return NO; }
        [out appendString:number.stringValue];
        return YES;
    }
    if ([value isKindOfClass:NSArray.class]) {
        [out appendString:@"["];
        BOOL first = YES;
        for (id element in value) {
            if (!first) [out appendString:@","];
            first = NO;
            if (!FDMAppendCanonical(out, element, error)) return NO;
        }
        [out appendString:@"]"];
        return YES;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSDictionary *object = value;
        [out appendString:@"{"];
        BOOL first = YES;
        for (NSString *key in [object.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (![key isKindOfClass:NSString.class]) { if (error) *error = FDMJSONError(@"对象键必须是字符串"); return NO; }
            if (!first) [out appendString:@","];
            first = NO;
            if (!FDMAppendCanonical(out, key, error)) return NO;
            [out appendString:@":"];
            if (!FDMAppendCanonical(out, object[key], error)) return NO;
        }
        [out appendString:@"}"];
        return YES;
    }
    if (value == NSNull.null) { [out appendString:@"null"]; return YES; }
    if (error) *error = FDMJSONError(@"不支持的值类型");
    return NO;
}

NSData *FDMJSONCanonicalData(id object, NSError **error) {
    NSMutableString *out = [NSMutableString string];
    if (!FDMAppendCanonical(out, object, error)) return nil;
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}

BOOL FDMJSONIsFiniteNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    return isfinite([value doubleValue]);
}

BOOL FDMJSONNonNegativeInteger(id value, unsigned long long maximum, unsigned long long *out) {
    if (!FDMJSONIsFiniteNumber(value)) return NO;
    NSDecimalNumber *decimal = [NSDecimalNumber decimalNumberWithString:[value stringValue]
                                                               locale:@{NSLocaleDecimalSeparator: @"."}];
    NSDecimalNumber *upper = [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%llu", maximum]];
    if ([decimal isEqual:NSDecimalNumber.notANumber] || [decimal compare:NSDecimalNumber.zero] == NSOrderedAscending ||
        [decimal compare:upper] == NSOrderedDescending) return NO;
    NSDecimalNumberHandler *integral = [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain scale:0
        raiseOnExactness:NO raiseOnOverflow:NO raiseOnUnderflow:NO raiseOnDivideByZero:NO];
    if ([decimal compare:[decimal decimalNumberByRoundingAccordingToBehavior:integral]] != NSOrderedSame) return NO;
    if (out) *out = decimal.unsignedLongLongValue;
    return YES;
}

BOOL FDMJSONFiniteDouble(id value, double *out) {
    if (!FDMJSONIsFiniteNumber(value)) return NO;
    if (out) *out = [value doubleValue];
    return YES;
}

NSString *FDMJSONStringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

NSArray *FDMJSONArrayValue(id value) {
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

NSDictionary *FDMJSONObjectValue(id value) {
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
