#!/bin/bash

cd ~

if [[ -d /etc/X11/xinit/xinitrc.d ]]; then
    for f in /etc/X11/xinit/xinitrc.d/*; do
        [[ -x "$f" ]] && . "$f"
    done
    unset f
fi

[[ -f ~/.Xresources ]] && xrdb -load ~/.Xresources

setxkbmap -layout us,el
setxkbmap -variant ,extended
setxkbmap -option
setxkbmap -option grp:rctrl_rshift_toggle

xsetroot -solid "#101010"
exec i3
