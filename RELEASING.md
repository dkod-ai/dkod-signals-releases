# Why every release gets its own commit

GitHub picks `releases/latest` by the date of the commit a release is tagged on,
not by version number. When every mirrored release points at the same commit,
"latest" is a coin flip: on 10 September 2026 one install got v0.1.46 while
v0.1.53 was current. Each release now moves `LATEST` in its own commit before the
tag is created, so the newest release always has the newest commit.
