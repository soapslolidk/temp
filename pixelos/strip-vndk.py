import re, os
S = os.environ.get("SRC", "/work/pixelos")
p = S + "/packages/modules/vndk/apex/Android.bp"
t = open(p).read()
t = re.sub(r'\n[a-z_]+ \{\n(?:(?!\n\}\n).)*?name: "com\.android\.vndk\.v(?:28|29|30)",.*?\n\}\n', '\n', t, flags=re.S)
open(p, "w").write(t)
p = S + "/build/make/target/product/gsi/Android.bp"
t = open(p).read()
t = re.sub(r'\n\s*\{\n\s*target: "/apex/com\.android\.vndk\.v(?:28|29|30)/lib(?:64)?",\n\s*name: "[^"]*",\n\s*\},', '', t)
open(p, "w").write(t)
