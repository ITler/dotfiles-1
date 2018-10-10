# Source the commands for python virtualenv
source /bin/virtualenvwrapper.sh

# Set name of the theme to load.
# Look in ~/.oh-my-zsh/themes/
# Optionally, if you set this to "random", it'll load a random theme each
# time that oh-my-zsh is loaded.
ZSH_THEME="ys"


# Uncomment the following line to enable command auto-correction.
#ENABLE_CORRECTION="true"

# Add wisely, as too many plugins slow down shell startup.
plugins=(git pass vi-mode autojump zsh-syntax-highlighting history-substring-search jira sprunge)

# load fash
eval "$(fasd --init auto)"

source $ZSH/oh-my-zsh.sh
