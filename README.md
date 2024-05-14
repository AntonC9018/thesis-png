## Setup instructions

```
git clone --recursive ...
```

Note that you won't be able to run it (as is), unless you're on WSL,
and the project is at an exact folder.
This is due to a bug in the Raylib bindings I'm using,
where a header file can't be imported by its relative path.
See [this GitHub issue](https://github.com/ryupold/raylib.zig/issues/39).
