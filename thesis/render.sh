if [ "$1" = "rerun" ]; then
    'latexmk' '--shell-escape' '-xelatex' 'main.tex' '-g'
else
    'latexmk' '--shell-escape' '-xelatex' 'main.tex'
fi
