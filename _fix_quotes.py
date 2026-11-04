import io

p = 'src/FocusDM.m'
s = io.open(p, encoding='utf-8').read()
NL = '\n'

bad = '%@: %@' + NL + '%@", e.name'
good = r'%@: %@\n%@", e.name'
n = s.count(bad)
s = s.replace(bad, good)

s = s.replace(r'componentsJoinedByString:@"\\n"', r'componentsJoinedByString:@"\n"')

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)

# 逐行检查引号奇偶，抓出仍然跨行的字符串字面量
s2 = io.open(p, encoding='utf-8').read().split(NL)
bad_lines = []
for i, line in enumerate(s2, 1):
    q = 0
    j = 0
    while j < len(line):
        if line[j] == '\\':
            j += 2
            continue
        if line[j] == '"':
            q += 1
        j += 1
    if q % 2:
        bad_lines.append((i, line))

print('joined literal newlines:', n)
print('odd-quote lines:', len(bad_lines))
for ln, text in bad_lines[:20]:
    print(ln, text)
