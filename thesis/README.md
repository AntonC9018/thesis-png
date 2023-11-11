How to compile the thesis:
- Install Python > 2.7 (Python 3 works);
- Install Pygments `pip install pygments` - used for code highlighting in latex;
- Install Latex, obviouly;
- I think you also need Perl, so install something like Cygwin or MinGW and add it to path (use the package manager if you're on Linux);
- Recursively clone `git clone --recursive whatever`;
- Run `render.bat` in `thesis`.

TODO: setup github action that would render it.
