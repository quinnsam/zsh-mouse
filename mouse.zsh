set-status() { return $1; }

handle_mouse_event0() {
  local bt=$1 mx=$2 my=$3 last_status=$4

  setopt extendedglob

  print -n '\e[6n' # query cursor position

  local i match mbegin mend buf=

  while read -k i \
    && buf+=$i \
    && [[ $buf != *\[([0-9]##)\;[0-9]##R ]]
  do :; done
  # read response from terminal.
  # note that we may also get a mouse tracking btn-release event,
  # which would then be discarded.

  # Match ANSI cursor position report (ESC [row;colR)
  [[ $buf = (#b)*\[([0-9]##)\;[0-9]##R ]] || return
  local cy=$match[1]

  local cur_prompt

  # trying to guess the current prompt
  case $CONTEXT in
    (vared)
      if [[ $0 = zcalc ]]; then
        cur_prompt=${ZCALCPROMPT-'%1v> '}
        setopt nopromptsubst nopromptbang promptpercent
        # (ZCALCPROMPT is expanded with (%))
      fi;;
      # if vared is passed a prompt, we're lost
    (select) cur_prompt=$PS3;;
    (cont) cur_prompt=$PS2;;
    (start) cur_prompt=$PS1;;
  esac

  # New logic: Expand prompt fully, then strip ANSI codes
  # This handles promptsubst and %F colors correctly
  set-status $last_status
  # Perform parameter expansion and command substitution (handle $(...))
  cur_prompt=${(e)cur_prompt}
  # Perform prompt expansion (handle %F, %~)
  cur_prompt=${(%)cur_prompt}
  # Strip CSI sequences (ending in a letter)
  cur_prompt=${cur_prompt//$'\e'[\[][0-9;]#[a-zA-Z]/}
  # Strip OSC sequences (Title bar), ending with BEL (\a)
  cur_prompt=${cur_prompt//$'\e'\][^$'\a']#$'\a'/}
  # Strip OSC sequences ending with ST (\e\)
  cur_prompt=${cur_prompt//$'\e'\][^$'\e']#$'\e'\\/}
  # Strip APC/Title sequences ending with ST (\ek...\e\)
  cur_prompt=${cur_prompt//$'\e'k[^$'\e']#$'\e'\\/}
  # Strip Charset selection (e.g. \e(0, \e(B)
  cur_prompt=${cur_prompt//$'\e'[()][0-9B]/}
  # Strip Shift-In/Shift-Out (SI/SO) \x0E \x0F
  cur_prompt=${cur_prompt//$'\x0e'/}
  cur_prompt=${cur_prompt//$'\x0f'/}

  # we're now looping over the whole editing buffer (plus the last
  # line of the prompt) to compute the (x,y) position of each char. We
  # store the characters i for which x(i) <= mx < x(i+1) for every
  # value of y in the pos array. We also get the Y(CURSOR), so that at
  # the end, we're able to say which pos element is the right one

  # array holding the possible positions of the mouse pointer
  local -a pos
  local -a end_pos # Track end of each line for fallback

  local -i i n x=0 y=1 cursor=$((${#cur_prompt}+$CURSOR+1))
  local Y

  buf=$cur_prompt$BUFFER
  for ((i=1; i<=$#buf; i++)); do
    (( i == cursor )) && Y=$y
    n=0
    case $buf[i] in
      ($'\n') # newline
        : ${pos[y]=$i}
        (( y++, x=0 ));;
      ($'\t') # tab advance til next tab stop
        (( x = x/8*8+8 ));;
      (*)
        n=${(m)#buf[i]};;
    esac
    while
      (( x >= mx )) && : ${pos[y]=$i}
      (( end_pos[y]=$i )) # Track last char of line
      (( x >= COLUMNS )) && (( x=0, y++ ))
      (( n > 0 ))
    do
      (( x++, n-- ))
    done
  done
  : ${pos[y]=$i} ${Y:=$y} ${end_pos[y]=$i}

  local mouse_CURSOR
  if ((my + Y - cy > y)); then
    mouse_CURSOR=$#BUFFER
  elif ((my + Y - cy < 1)); then
    mouse_CURSOR=0
  else
    local target_y=$((my + Y - cy))
    # If pos unset (click past end), use end_pos
    local target_pos=${pos[target_y]:-$end_pos[target_y]}
    mouse_CURSOR=$(($target_pos - ${#cur_prompt} - 1))
  fi

  case $bt in
    (0)
      # Button 1.  Move cursor.
      CURSOR=$mouse_CURSOR
    ;;

    (1)
      # Button 2.  Insert selection at mouse cursor postion.
      BUFFER=$BUFFER[1,mouse_CURSOR]$CUTBUFFER$BUFFER[mouse_CURSOR+1,-1]
      (( CURSOR = $mouse_CURSOR + $#CUTBUFFER ))
    ;;

    (2)
      # Button 3.  Copy from cursor to mouse to cutbuffer.
      killring=("$CUTBUFFER" "${(@)killring[1,-2]}")
      if (( mouse_CURSOR < CURSOR )); then
        CUTBUFFER=$BUFFER[mouse_CURSOR+1,CURSOR+1]
      else
        CUTBUFFER=$BUFFER[CURSOR+1,mouse_CURSOR+1]
      fi
    ;;
  esac
}

# SGR 1006 Handler
handle_sgr_mouse_event() {
  local last_status=$?
  emulate -L zsh
  local bt mx my char sgr_data
  
  # Read until M or m
  while read -k char; do
    sgr_data+=$char
    [[ $char == [Mm] ]] && break
  done
  
  # Parse b;x;y
  local -a parts
  parts=("${(@s/;/)${sgr_data[1,-2]}}")
  bt=$parts[1]
  mx=$parts[2]
  my=$parts[3]
  local type=$sgr_data[-1]
  
  # Check for Release (m)
  if [[ $type == 'm' ]]; then
     return
  fi

  # Call common logic
  handle_mouse_logic $bt $mx $my $last_status
}

# Legacy X10/1000 Handler
handle_mouse_event_x10() {
  local last_status=$?
  emulate -L zsh
  local bt mx my

  read -k bt
  read -k mx
  read -k my

  # Decode X10/1000 encoding: Value = Byte - 32
  bt=$((#bt - 32))

  if [[ "$mx" == "\x18" ]]; then
    # assume event is \E[M<btn>dired-button()(^X\EG<x><y>)
    read -k mx
    read -k mx
    read -k my
    (( my = #my - 31 ))
    (( mx = #mx - 31 ))
  else
    (( my = #my - 32 ))
    (( mx = #mx - 32 ))
  fi
  
  # Scroll wheel events: Wheel Up=64, Down=65 (after -32 decode).
  # Route through handle_mouse_logic so tmux copy-mode is triggered.
  handle_mouse_logic $bt $mx $my $last_status
}

# Common Logic for Click/Drag/Scroll
handle_mouse_logic() {
  local bt=$1 mx=$2 my=$3 last_status=$4

  # Handle Scroll Wheel events (bt 64=up, 65=down)
  if (( bt == 64 || bt == 65 )); then
    if [[ -n "$TMUX" ]]; then
      tmux copy-mode
    fi
    return
  fi

  # Handle Drag events (bit 5 set, +32)
  if (( bt & 32 )); then
    local drag_btn=$(( bt & ~32 ))
    # Only drag with Left Button (0)
    if [[ $drag_btn -eq 0 ]]; then
       # If in tmux, trigger copy-mode on drag
       if [[ -n "$TMUX" ]]; then
         tmux copy-mode
         return
       fi

       handle_mouse_event0 $drag_btn $mx $my $last_status
       REGION_ACTIVE=1
    fi
    return
  fi

  # Handle Click events
  if [[ $bt -eq 0 ]]; then
    handle_mouse_event0 $bt $mx $my $last_status
    MARK=CURSOR
    REGION_ACTIVE=0
  else
    handle_mouse_event0 $bt $mx $my $last_status
  fi
}

zle -N handle_mouse_event_x10
zle -N handle_sgr_mouse_event

zmodload -i zsh/parameter # needed for $functions
# Enable 1002 (Drag) and 1006 (SGR).
functions[precmd]+='print -n '\''\e[?1002;1006h'\'
functions[preexec]+='print -n '\''\e[?1002;1006l'\'

bindkey -M emacs '\e[M' handle_mouse_event_x10
bindkey -M viins '\e[M' handle_mouse_event_x10
bindkey -M vicmd '\e[M' handle_mouse_event_x10

# Bind SGR Subevent
bindkey -M emacs '\e[<' handle_sgr_mouse_event
bindkey -M viins '\e[<' handle_sgr_mouse_event
bindkey -M vicmd '\e[<' handle_sgr_mouse_event
