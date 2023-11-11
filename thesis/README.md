How to compile the thesis:
- Install Python > 2.7 (Python 3 works);
- Install Pygments `pip install pygments` - used for code highlighting in latex;
- Install Latex, obviouly;
- Install DMD;
- I think you also need Perl, so install something like Cygwin or MinGW and add it to path (use the package manager if you're on Linux);
- Recursively clone `git clone --recursive whatever`;
- Run `dmd -run build.d` in `thesis`. It will spit out a bunch of temp files in that directory, and then a `teza_processed.pdf` file with the output.
