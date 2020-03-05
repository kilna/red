#!/usr/bin/env bash

if [ ! "$BASH" ]; then
  echo "Script is only compatible with bash, current shell is $SHELL" >&2
  exit 1
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cat <<EOF >&2
This script is meant to be added into a Bash shell session.

source /path/to/red

After loading via source, you can use 'red reload' to reload.
EOF
  exit 1
fi

red_root="$(cd $(dirname ${BASH_SOURCE[0]}); echo $PWD)"
red_script="${red_root}/$(basename ${BASH_SOURCE[0]})"

trap "$(shopt -p extglob)" RETURN
shopt -s extglob

red() {

  #for var in $(red::vars); do
  #  [[ "$var" != 'red_ps1_orig' ]] && unset $var
  #done

  eval "$( CFGFLAGS='-c|--config' CFGFILES=$HOME/.redrc? red::cfg "$@" )"

  local load_modules=(error)
  local show_help=0
  local ar=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help)         show_help=1 ;;
      -m|--module)       load_modules+=("$2"); shift ;;
      #-a|--all-modules)  all_modules=1 ;;
      -d|--debug)        red::enable debug ;;
      -l|--powerline)    red::enable powerline ;;
      -w|--doublewide)   red::enable doubelwide ;;
      #-b|--bold)         red::enable bold ;;
      #-s|--style)        red_styles="$2 ${red_styles}"; shift ;;
      #-u|--user-style)   user_styles+=("$2"); shift ;;
      -c|--colors)       red::set ansi_color_depth "$2"; shift ;;
      *)                 ar+=("$1") ;;
    esac
    shift
  done
  set -- "${ar[@]}"
  unset ar
  if (( $show_help )); then set -- help "$@"; fi

  if [[ "$red_ansi_color_depth" != +(0|8|16|256|24bit) ]]; then
    IFS='' read -r red_ansi_color_depth < <(red::ansi_color_depth)
  fi

  #red::debug "red_root: $red_root"
  #red::debug "red_script: $red_script"

  #if [[ "$all_modules" ]]; then
  #  load_modules=()
  #  for module_path in $red_root/module/*; do
  #    load_modules+=("${module_path##*/}")
  #  done
  #fi
  #unset all_modules

  for func in $(red::funcs); do
    case "$func" in red::module::*)
      red::debug "Unsetting $func"
      unset -f $func;;
    esac
  done

  red::unset loaded_modules
  for module in "${load_modules[@]}"; do
    red::debug "Loading module: $module"
    source "${red_root}/module/${module}"
    IFS='' read -r error < <(red::get module_${module}_error)
    if [[ "$error" == '' ]] && ! typeset -F red::module::$module &>/dev/null
    then
      error="Function red::module::$module is missing"
    fi
    if [[ "$error" ]]; then
      echo "Error loading module $module: $error" >&2
      return 1
    fi
    red::addlist loaded_modules $module
    red::debug "Module $module loaded successfully"
  done
  red::debug Final loaded modules: "${red_loaded_modules[@]}"

  # Process multiple verbs delimited by --
  while (( $# > 0 )); do
    local action="$1"
    shift
    local ar=()
    while [[ $# -gt 0 && "$1" != '--' ]]; do
      ar+=("$1")
      shift
    done
    shift
    red::$action "${ar[@]}"
  done

}

red::uc() {
  if (( "${BASH_VERSINFO[0]}" > 3 )); then echo "${1^^}"
  else echo "$1" | tr a-z A-Z ;fi
}

red::pager() {
  for pager in $PAGER less more cat; do
    which $pager &>/dev/null && cat - | $pager && break
  done
}

# Escapes list entries (if needed) such that they can be eval'd in Bash
red::esc() {
  while (( $# > 0 )); do
    if [[ "$1" =~ ^[a-zA-Z0-9_.,:=+/-]+$ ]]; then
      echo -n $1
    else
      echo -n \'${1//\'/\'\\\'\'}\'
    fi
    shift
    (( $# > 0 )) && echo -n ' '
  done
  echo # End with a newline... this'll be removed it run from $(...) anyway
}

red::cfg() {

  # Clean up / unify contents of $@
  local ar=()
  local a
  while (( $# > 0 )); do
    a="$1"; shift
    case "$a" in
      --*=*) ar+=("${a%%=*}" "${a#*=}");; # break --foo=bar into --foo bar
      --*)   ar+=("$a");; # Match --flags so we skip next line
      -*)    # Unbundle grouped single-letter flags
             for (( x=1; x<${#a}; x++ )); do ar+=("-${a:$x:1}"); done;;
      *)     ar+=("$a");; # Any other kind of argument is passed through
    esac
  done
  set -- "${ar[@]}"

  # Resolve passed in config file parameters into cfgfiles array
  ar=()
  IFS=:   read -a cfgfiles <<< "$CFGFILES"
  IFS='|' read -a cfgflags <<< "$CFGFLAGS"
  local match
  while (( $# > 0 )); do
    a="$1"; shift
    match=''
    for param in "${cfgflags[@]}"; do
      if [[ "$a" == "$param" ]]; then
        match="$1"
        shift
        break
      fi
    done
    if [[ "$match" ]]; then
      cfgfiles+=("$match")
    else
      ar+=("$a")
    fi
  done
  set -- "${ar[@]}"

  # Process each config file into additional $@ parameters
  for file in "${cfgfiles[@]}"; do
    # Files ending with ? are optional, skip if not present
    if [[ "${file%'?'}" != "$file" ]]; then
      file="${file%'?'}"
      [[ ! -e $file ]] && continue
    fi
    local prefix='--'
    while IFS='' read line; do
      line="${line##+([[:space:]])}" # Remove spaces from beginning of line
      line="${line%%+([[:space:]])}" # Remove spaces from end of line
      case "$line" in
        ''|'#'*)  : ;; # Skip blank or comment lines
        '['*']')  # Config file sections get turned into option prefixes
                  # e.g., an option "bar" in section "[foo]" will become
                  # --foo-bar
                  prefix="${line:1:$(( ${#line} - 2))}"
                  prefix="${prefix##+([[:space:]])}"
                  prefix="${prefix%%+([[:space:]])}"
                  prefix="--${prefix}-";;
        *=*)      # Break foo=bar into --foo bar
                  local key="${line%%+([[:space:]])=*}"
                  local val="${line##*=+([[:space:]])}"
                  set -- "$@" "$prefix$key" "$val";;
        *)        set -- "$@" "$prefix$line";;
      esac
    done <"$file"
  done

  # Generate a set statement to be eval'd, which will recreate $@
  # normalized, with all of the values from the config files in place
  red::esc set -- "$@"

}

red::remap_ansi_colors() {
  local pre='\033]'
  local post='\033\\'
  if [[ -n "$TMUX" ]]; then
    pre='\033Ptmux;\033\033]'
    post='\033\033\\\033\\'
  elif [[ "${TERM%%[-.]*}" = "screen" ]]; then
    pre='\033P\033]'
    post='\007\033\\'
  elif [[ "${TERM%%-*}" = "linux" ]]; then
    return
  fi
  local ct="${pre}4;%d;rgb:%s$post" # Set color template
  local it="$pre%s%s$post" # Set iterm template
  local vt="$pre%s;rgb:%s$post" # Set var template
  while [[ $# -gt 0 ]]; do
    local spec="$1"; shift
    local color="${spec%%=*}"
    local rgb="${spec#*=}"
    rgb="${rgb#'#'}" # Remove optional leading hash from RGB code
    if [[ "$rgb" == [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f] ]]; then
      # 3 digit to 6 digit hex RGB codes
      rgb="${rgb:0:1}${rgb:0:1}${rgb:1:1}${rgb:1:1}${rgb:2:1}${rgb:2:1}"
    elif [[ "$rgb" != +([0-9A-Fa-f]) || "${#rgb}" -ne 6 ]]; then
      echo "Unrecognized RGB color value: $rgb" >&2
      continue
    fi
    local rgb_s="${rgb:0:2}/${rgb:2:2}/${rgb:4:2}"
    case "$color" in
       *s)              local c="${color%s}" # reds -> red, brightred
                        red::remap_ansi_colors $c=$rgb bright$c=$rgb;;
       blackbg)         red::remap_ansi_colors black=$rgb bg=$rgb;;
       whitebg)         red::remap_ansi_colors brightwhite=$rgb bg=$rgb;;
       blackfg)         red::remap_ansi_colors black=$rgb fg=$rgb;;
       whitefg)         red::remap_ansi_colors brightwhite=$rgb fg=$rgb;;
       fg)              if [[ -n "$ITERM_SESSION_ID" ]]; then
                          printf $it Pg $rgb
                          printf $it Pi $rgb
                        else
                          printf $vt 10 $rgb_s
                        fi;;
       bg)              if [[ -n "$ITERM_SESSION_ID" ]]; then
                          printf $it Ph $rgb
                        else
                          printf $vt 11 $rgb_s
                          if [[ "${TERM%%-*}" == "rxvt" ]]; then
                            printf $vt 708 $rgb_s
                          fi
                        fi;;
      [0-9]+)           printf $ct $color $rgb_s;;
      black)            printf $ct  0 $rgb_s;;
      red)              printf $ct  1 $rgb_s;;
      green)            printf $ct  2 $rgb_s;;
      yellow)           printf $ct  3 $rgb_s;;
      blue)             printf $ct  4 $rgb_s;;
      magenta)          printf $ct  5 $rgb_s;;
      cyan)             printf $ct  6 $rgb_s;;
      white|lightgray)  printf $ct  7 $rgb_s;;
      brightblack|gray) printf $ct  8 $rgb_s;;
      brightred)        printf $ct  9 $rgb_s;;
      brightgreen)      printf $ct 10 $rgb_s;;
      brightyellow)     printf $ct 11 $rgb_s;;
      brightblue)       printf $ct 12 $rgb_s;;
      brightmagenta)    printf $ct 13 $rgb_s;;
      brightcyan)       printf $ct 14 $rgb_s;;
      brightwhite)      printf $ct 15 $rgb_s;;
      *)                echo "Unrecognized color specification: $1" 1>&2;;
    esac
  done
}

red::set()     { export red_$1="$2"; }
red::enable()  { export red_$1=1; }
red::disable() { export red_$1=0; }
red::unset()   { unset red_$1; }
red::get()     { local varname=red_$1; echo -n "${!varname}"; }

# Set a variable if it hasn't already been set
red::ensure() {
  local varname=red_$1
  [[ "${!varname}" == '' ]] && red::set "$@"
}

red::setlist() {
  local varname=red_$1
  shift
  export $varname
  eval "$varname=( $(red::esc "$@") )"
}

red::addlist() {
  local varname=red_$1
  shift
  export $varname
  eval "$varname=( \"\${${varname}[@]}\" $(red::esc "$@") )"
}

red::check() {
  local varname=red_$1
  local compareval="${2:-1}"
  local defaultval="${3:-}"
  [[ "${!varname}" == '' && "$defaultval" == "$compareval" ]] && return 0
  [[ "${!varname}" == "$compareval" ]] && return 0
  return 1
}

red::reload() {
  red::debug "Reloading $red_script"
  red::unload
  if [[ -e $red_script ]]; then
    source $red_script "$@"
  else
    echo "Unable to find red_script: $red_script" >&2
    return 1
  fi
}

red::unload() {
  if [[ "$red_ps1_orig" != '' ]]; then export PS1="$red_ps1_orig"; fi
  local debug="${red_debug:-0}"
  for var in $(red::vars); do
    (( $debug )) && echo "Unsetting \$${var}" >&2
    unset $var &>/dev/null
  done
  for func in $(red::funcs); do
    (( $debug )) && echo "Unsetting ${func}()" >&2
    unset -f $func &>/dev/null
  done
}

#red::lookup() {
#  local funcname="red::${1//_/::}"
#  if typeset -F $funcname; then
#    $funcname
#    return $?
#  fi
#  local varname="red_${1//::/_}"
#  if typeset $varname; then
#    echo -n ${!varname}
#    return 0
#  fi
#  return 1
#}

red::funcs() {
  while IFS='' read line; do
    local f=($line)
    [[ "${f[0]}" == 'declare' && "${f[2]}" == 'red::'* ]] || continue
    echo "${f[2]}"
  done < <(typeset -pF)
}

red::vars() {
  while IFS='' read line; do
    local f=($line)
    [[ "${f[0]}" == 'declare' && "${f[2]}" == 'red_'* ]] || continue
    echo "${f[2]%%=*}"
  done < <(typeset -px; typeset -pax)
}

red::debug() {
  if ! red::check debug; then set +x; return; fi
  if (( $# > 1 )); then red::esc "$@" >&2 # Escape if we're passed a list
  else echo "$1" >&2; fi # Otherwise dump just $1 verbatim
}

red::unicode() {
  [[ "$LANG" == *'UTF-8'* ]] && return 0
  return 1
}

red::powerline() {
  red::unicode || return 1
  red::check powerline || return 1
  return 0
}

export red_scheme=''
export red_style_default=''
export red_style_user='{fg:cyan}'
export red_style_host='{fg:magenta}'
export red_style_fqdn='{fg:magenta}'
export red_style_dir='{fg:green}'
export red_style_time='{fg:yellow}'
export red_style_time12='{fg:yellow}'
export red_style_date='{fg:yellow}'
export red_style_ampm='{fg:yellow}'
export red_style_module='{reverse}{space}'
export red_style_module_end='{space}{/reverse}'
export red_style_module_pad='{space}'
export red_style_module_symbol_pad='{space}'

#red::load_style() {
#  local file="$1"
#  local is_unicode=0
#  local code=''
#  while IFS='' read line; do
#    [[ "$line" == '#'* || "$line" =~ ^[[:space:]]*$ ]] && continue
#    if [[ "$line" != *':'* ]]; then
#      echo "Unable to parse line '$line' in file '$file'" >&2
#      continue
#    else
#      name="${line%%=*}"
#      name="${name## }"
#      name="${name%% }"
#      val="${line#*=}"
#      val="${val## }"
#      val="${val%% }"
#      #[[ "$val" == *'{u:'* ]] && is_unicode=1
#      #code+="export red_style_${name^^}='${val//\'/\\\'}'"$'\n';
#      red::set style_${name} "{$val}"
#    fi
#  done < "$1"
#  #if [[ ! red::unicode && is_unicode ]]; then
#  #  echo "File '$file' contains unicode style information but terminal is not UTF-8" >&2
#  #fi
#  #eval "$code"
#}

# Parse strings like '{tag}foo{/tag}' into a eval-able set statement to change
# $@ to the string chunked into a list of '{tag}' 'foo' '{/tag}'
red::parse_markup() {
  local ar=()
  for str in "$@"; do
    while [[ "$str" != '' ]]; do
      x="${str%%\{*}"
      [[ "$x" = "$str" ]] || idx1=$(( ${#x} + 1 ))
      x="${str%%\}*}"
      [[ "$x" = "$str" ]] || idx2=$(( ${#x} + 1 ))
      nontag_val=''
      tag_val=''
      if [[ "$idx1" != '' && "$idx2" != '' && (( idx2 > idx1 )) ]]; then
        substr="${str:0:$idx2}"
        x="${substr%\{*}"
        [[ "$x" = "$substr" ]] || idx1=$(( ${#x} + 1 ))
        if [[ "$idx1" == '' ]]; then
          nontag_val+="$substr"
        else
          idx1x=$(( idx1 - 1 ))
          if (( idx1 != 0 )); then
            nontag_val+="${str:0:$idx1x}"
          fi
          idx2x=$(( idx2 - idx1 + 1 ))
          tag_val="${str:$idx1x:$idx2x}"
        fi
        str="${str:$idx2}"
      else
        nontag_val+="$str"
        str=''
      fi
      ar_idx=$(( ${#ar[@]} - 1 ))
      if [[ "$nontag_val" != '' ]]; then
        if [[ "$ar_idx" -lt 0 || "${ar[$ar_idx]}" == '{'*'}' ]]; then
          ar+=("$nontag_val")
        else
          ar[$ar_idx]+="$nontag_val"
        fi
      fi
      if [[ "$tag_val" != '' ]]; then
        ar+=("$tag_val")
      fi
    done
  done
  red::esc set -- "${ar[@]}" # Make eval-able set command for new desired $@
}

# Renders escaped ANSI as actual ANSI, if the terminal is ANSI enabled
red::ansi_echo() {
  red::check ansi_color_depth 0 0 && return
  if (( "${BASH_VERSINFO[0]}" > 3 )); then
    echo -en "$1"
  else
    printf "${1//%/%%}"
  fi
}

red::color_as_e_ansi() {

  # If we're foreground $a is set to 3, if background it's set to 4
  local a='3'; if [[ "${1:0:2}" == 'bg' ]]; then a='4'; fi

  local spec="${1:3}"

  local r g b

  case "$spec" in
    black)            echo -n '\e['"${a}0m";;
    red)              echo -n '\e['"${a}1m";;
    green)            echo -n '\e['"${a}2m";;
    yellow)           echo -n '\e['"${a}3m";;
    blue)             echo -n '\e['"${a}4m";;
    magenta)          echo -n '\e['"${a}5m";;
    cyan)             echo -n '\e['"${a}6m";;
    white|lightgray)  echo -n '\e['"${a}7m";;
    brightblack|gray) echo -n '\e['"${a}8m";;
    brightred)        echo -n '\e['"${a}9m";;
    brightgreen)      echo -n '\e['"${a}10m";;
    brightyellow)     echo -n '\e['"${a}11m";;
    brightblue)       echo -n '\e['"${a}12m";;
    brightmagenta)    echo -n '\e['"${a}13m";;
    brightcyan)       echo -n '\e['"${a}14m";;
    brightwhite)      echo -n '\e['"${a}15m";;
    +([0-9]))         echo -n '\e['"${a}8;5;${spec}m";;
    +([0-9]),+([0-9]),+([0-9]))
                      local rgb=( ${spec//,/ } )
                      r="${rgb[0]}"; g="${rgb[1]}"; b="${rgb[2]}";;
    '#'[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
                      r="$(( 16#${spec:1:2} ))"
                      g="$(( 16#${spec:3:2} ))"
                      b="$(( 16#${spec:5:2} ))";;
    '#'[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])
                      r="$(( ( 16#${spec:1:1} * 16 ) + 16#${spec:1:1} ))"
                      g="$(( ( 16#${spec:2:1} * 16 ) + 16#${spec:2:1} ))"
                      b="$(( ( 16#${spec:3:1} * 16 ) + 16#${spec:3:1} ))";;
  esac

  [[ "$r$g$b" == '' ]] && return

  # If we're in 24 bit mode we don't have to round, return using RGB syntax
  if red::check ansi_color_depth '24bit'; then
    echo -n '\e['"${a}8;2;${r};${a};${b}m"
    return
  fi

  # Below rounds to the nearest ANSI 216 color cube or 24 grayscale value. See:
  # https://docs.google.com/spreadsheets/d/1n4zg5OXYC0hBdRKBb1clx4t2HSx_cu_iiot6GYpgh1c/
  local min=''
  local max=''
  local total=0
  for c in $r $g $b; do
    if [[ "$min" == '' ]] || (( c < min )); then min="$c"; fi
    if [[ "$max" == '' ]] || (( c > max )); then max="$c"; fi
    total=$(( total + c ))
  done

  local idx=''
  if (( ( max - min ) <= 26 )); then
    # If the delta between min and max is less than 26 (roughly 1/2 the 51.2
    # shades per 6x6x6 colors) then the color is effectively gray.
    local gray=$(( total / 3 )) # RGB averaged into single 0-255 gray value
    if ((
      ( gray >= 8   && gray < 51  ) || ( gray >= 58  && gray < 102 ) ||
      ( gray >= 108 && gray < 153 ) || ( gray >= 158 && gray < 204 ) ||
      ( gray >= 208 && gray < 248 )
    )); then
      # If we aren't better matched to the 6x6x6 cube, use a 24-shade ANSI gray
      idx=$(( 230 + ( ( $gray + 12 ) / 10 ) ))
    fi
  fi

  if [[ "$idx" == '' ]]; then
    # Otherwise, map to ANSI 216 indexed color cube
    idx=$((
      16 + ( ( ( $r + 26 ) / 51 ) * 36 ) + ( ( ( $g + 26 ) / 51 ) * 6  )
         + ( ( ( $b + 26 ) / 51 ) * 1  )
    ))
  fi

  echo -n '\e['"${a}8;5;${idx}m"
}

red::style_ansi() {
  local varname="red_style_$1"
  red::render_ansi "${!varname}"
}

red::style_wrap_ansi() {
  local style="$1"
  local content="$2"
  red::style_ansi "${style}"
  echo -n "$content"
  red::style_ansi "${style}_end"
}

red::render_ansi() {
  case "$1" in
    -p|--preparsed) shift ;; # Do nothing
    *) eval "$(red::parse_markup "$@")";; # Chunk input by {tag}
  esac
  while (( $# > 0 )); do
    arg="$1"
    shift
    [[ "$arg" != '{'*'}' ]] && echo -n "${arg//\\/\\\\}" && continue
    tag="${arg:1:$(( ${#arg} - 2 ))}"
    case "$tag" in
      style:*)    red::style_e_ansi "${tag:6}";;
      /style:*)   red::style_e_ansi "${tag:7}_end";;
      space)      red::ansi_echo ' ';;
      eol)        red::ansi_echo '\n\e[0m';;
      clear)      red::ansi_echo '\e[H\e[2J';;
      reset)      red::ansi_echo '\e[0m';;
      fg:*|bg:*)  IFS='' read -r e_ansi < <(red::color_as_e_ansi $tag)
                  red::ansi_echo "$e_ansi";;
      bold)       red::ansi_echo '\e[1m';;
      /bold)      red::ansi_echo '\e[21m';;
      dim)        red::ansi_echo '\e[2m';;
      /dim)       red::ansi_echo '\e[22m';;
      italic)     red::ansi_echo '\e[3m';;
      /italic)    red::ansi_echo '\e[23m';;
      underline)  red::ansi_echo '\e[4m';;
      /underline) red::ansi_echo '\e[24m';;
      blink)      red::ansi_echo '\e[5m';;
      /blink)     red::ansi_echo '\e[25m';;
      fastblink)  red::ansi_echo '\e[6m';;
      /fastblink) red::ansi_echo '\e[26m';;
      reverse)    red::ansi_echo '\e[7m';;
      /reverse)   red::ansi_echo '\e[27m';;
      hidden)     red::ansi_echo '\e[8m';;
      /hidden)    red::ansi_echo '\e[28m';;
      *)          "${arg}";;
    esac
  done
}

red::style_ps1() {
  local varname="red_style_$1"
  red::render_ps1 "${!varname}"
}

red::style_wrap_ps1() {
  local style="$1"
  local content="$2"
  red::style_ps1 "${style}"
  echo -n "$content"
  red::style_ps1 "${style}_end"
}

red::render_ps1() {
  case "$1" in
    -p|--preparsed) shift ;; # Do nothing
    *) eval "$(red::parse_markup "$@")";; # Chunk input by {tag}
  esac
  red::debug 'render_ps1:' "$@"
  while (( $# > 0 )); do
    arg="$1"
    shift
    [[ "$arg" != '{'*'}' ]] && echo -n "$arg" && continue
    tag="${arg:1:$(( ${#arg} - 2 ))}"
    case "$tag" in
      style:*)     red::style_ps1 "${tag:6}";;
      /style:*)    red::style_ps1 "${tag:7}_end";;
      space)       echo -n ' ';;
      eol)         echo -n '\n\[\e[0m\]';;
      clear)       echo -n '\[\e[H\e[2J\]';;
      reset)       echo -n '\[\e[0m\]';;
      fg:*|bg:*)   echo -n '\['; red::color_as_e_ansi "$tag"; echo -n '\]';;
      bold)        echo -n '\[\e[1m\]';;
      /bold)       echo -n '\[\e[21m\]';;
      dim)         echo -n '\[\e[2m\]';;
      /dim)        echo -n '\[\e[22m\]';;
      italic)      echo -n '\[\e[3m\]';;
      /italic)     echo -n '\[\e[23m\]';;
      underline)   echo -n '\[\e[4m\]';;
      /underline)  echo -n '\[\e[24m\]';;
      blink)       echo -n '\[\e[5m\]';;
      /blink)      echo -n '\[\e[25m\]';;
      fastblink)   echo -n '\[\e[6m\]';;
      /fastblink)  echo -n '\[\e[26m\]';;
      reverse)     echo -n '\[\e[7m\]';;
      /reverse)    echo -n '\[\e[27m\]';;
      hidden)      echo -n '\[\e[8m\]';;
      /hidden)     echo -n '\[\e[28m\]';;
      user)        red::style_wrap_ps1 'user' '\u';;
      dir)         red::style_wrap_ps1 'dir' '\w';;
      basename)    red::style_wrap_ps1 'basename' '\W';;
      host)        red::style_wrap_ps1 'host' '\h';;
      fqdn)        red::style_wrap_ps1 'fqdn' '\H';;
      prompt)      red::style_wrap_ps1 'prompt' '\$';;
      date)        red::style_wrap_ps1 'date' '\d';;
      time)        red::style_wrap_ps1 'time' '\t';;
      time12)      red::style_wrap_ps1 'time12' '\T';;
      ampm)        red::style_wrap_ps1 'ampm' '\@';;
      module:*)    echo -n '`red::module '${tag:8}'`';;
      modules)     echo -n '`red::modules`';;
      modules:eol) echo -n '`red::modules -n`';;
      modules:pad) echo -n '`red::modules -p`';;
      *)           echo -n "{$tag}";;
    esac
  done
}

red::module() {
  red::ensure module_error_last_exit "$?" # Cache last command's error...
  red::debug ">module $1"
  module="$1"
  red::module::$module
  local varname="red_module_${module}_content"
  local content="${!varname}"
  [[ "$content" ]] || return
  red::debug "  content: $content"
  for varname in color symbol_powerline symbol_unicode symbol_ascii; do
    local varnamefull="red_module_${module}_${varname}"
    local value="${!varnamefull}"
    eval "local $varname='${value//\'/\'\\\'\'}'"
  done
  red::style_ansi module
  red::debug 'red::powerline: '$(red::powerline; if [[ "$?" == 0 ]]; then echo true; else echo false; fi )
  red::debug "symbol_powerline='$symbol_powerline'"
  red::debug 'red::unicode: '$(red::unicode; if [[ "$?" == 0 ]]; then echo true; else echo false; fi )
  red::debug "symbol_unicode='$symbol_unicode'"
  red::debug "symbol_ascii='$symbol_ascii'"
  if red::powerline && [[ "$symbol_powerline" ]]; then
    echo -n "$symbol_powerline"
    red::style_ansi module_symbol_pad
  elif red::unicode && [[ "$symbol_unicode" ]]; then
    echo -n "$symbol_unicode"
    red::style_ansi module_symbol_pad
  elif [[ "$symbol_ascii" ]]; then
    echo -n "$symbol_ascii"
    red::style_ansi module_symbol_pad
  fi
  echo -n "$content"
  red::style_ansi module_end
  exit $red_module_error_last_exit
}

red::modules() {
  red::ensure module_error_last_exit "$?" # Cache last command's error...
  red::debug ">modules"
  #red::enable debug
  local newline=0
  if [[ "$1" == '-n' ]]; then
    newline=1
    shift
  fi
  local pad=0
  if [[ "$1" == '-p' ]]; then
    pad=1
    shift
  fi
  red::render_ansi -p '{reset}'
  local all_out=''
  local count=0
  local module_last_color=''
  for module in ${red_loaded_modules[@]}; do
    count=$(( count++ ))
    IFS='' read -r out < <(red::module ${module})
    [[ "$out" ]] || continue
    all_out+="$out"
    local varname="module_${module}_color"
    red::set module_last_color "${!varname}"
    if (( $count < "${#red_loaded_modules[@]}" )); then
      IFS='' read -r pad < <(red::style_ansi module_pad)
      all_out+="$pad"
    fi
  done
  echo -n "$all_out"
  red::render_ansi -p '{reset}'
  if [[ "$all_out" != '' ]]; then
    if [[ "$newline" == 1 ]]; then
      red::render_ansi -p '{eol}'
    elif [[ "$pad" == 1 ]]; then
      red::style_ansi 'module_pad'
    fi
  fi
  exit $red_module_error_last_exit
}

red::ansi_color_depth() {
  case "$TERM$COLORTERM" in
    *truecolor*|*24bit*) echo '24bit'; return;;
    *256*)               echo '256';   return;;
  esac
  local infocmp
  IFS='' read -r infocmp < <(infocmp 2>/dev/null)
  if [[ "$infocmp" == *+([[:space:]])@(set24f|setf24|setrgbf)=* ]]; then
    echo '24bit'
    return
  fi
  local ansi
  IFS='' read -r ansi < <(printf '\e]4;1;?\a')
  local REPLY
  read -p "$ansi" -d $'\a' -s -t 0.1 </dev/tty
  if ! [[ -z "$REPLY" ]]; then
    local colors=''
    for idx in 255 15 7; do
      IFS='' read -r ansi < <(printf '\e]4;%d;?\a' $idx)
      read -p "$ansi" -d $'\a' -s -t 0.1 </dev/tty
      if ! [[ -z "$REPLY" ]]; then
        echo $(( idx + 1 ))
        return
      fi
    done
  fi
  local tput
  IFS='' read -r tput < <(tput colors 2>/dev/null)
  if (( tput == 8 || tput == 16 || tput == 256 )); then
    echo "$tput"
    return
  fi
  echo 0
}

red::help() {
  if [[ "$1" != '' ]] && typeset -F red::help::$1; then
    local verb="$1"
    shift
    red::help::$verb "$@"
  else
    echo "HELP!"
  fi
}

red::help::prompt() {
  red::pager <<EOF
USAGE: source red [options]

Sets the prompt in a bash session

Options:

         --module NAME :  Enable module NAME
               -m NAME    Modules can be found in:
                            $red_root/module

         --all-modules :  Enable all modules
                    -a

          --style NAME :  Enable style NAME
               -s NAME    Styles can be found in:
                            $red_root/style

         --colors SPEC :  Override auto-detection for the number of ANSI colors
               -c SPEC      the current terminal supports.

                          SPEC is one of:
                            0       No ANSI color support
                            8
                            16
                            256
                            24bit   Truecolor ANSI terminal support

           --powerline :  Use Powerline font symbols
                    -l

                --bold :  Bold all styles
                    -b

                --help :  Shows help
                    -h

               --debug :  Enable debugging information
                    -d

 --title-format FORMAT :  Format for status line / window title using bash
             -f FORMAT    PS1 syntax

     --title-mode MODE :  Sets how status line / window title is handled
               -t MODE    Custom titles can be set with the 'title' command

                          MODE is one of:
                            prepend      Add custom-set title as the
                                         begining (default)

                            append       Add custom-set title at the end

                            static       No custom-set title

                            interpolate  Interpolate escape \\z in
                                         title-format as custom set title

                            disabled     No title set in prompt

For more information and additonal usage: https://github.com/kilna/prompt
EOF
}

red::pre_prompt() {
  red::ensure module_error_last_exit "$?" # Cache last command's error...
  red::debug ">pre_prompt"
#  if [[ "$red_title" ]]; then
#    case "$red_title_mode" in
#      prepend)     echo -n "$red_title"' - ';;
#      append)      echo -n ' - '"$red_title";;
#      interpolate) echo -n "$red_title";;
#      interpolate) echo -n "${red_title_format//\\z/'`red::title`'}";;
#    esac
#  fi
  return $red_module_error_last_exit
}

#red::post_prompt() {
#  red::ensure module_error_last_exit "$?" # Cache last command's error...
#  exit $
#}


#red::title_ps1() {
#  if [[ "$red_title_mode" != 'disabled' ]]; then
#    echo -n '\[\e]0;\]'
#    case "$red_title_mode" in
#      static)      echo -n "$red_title_format";;
#      prepend)     echo -n '`red::title`'"$red_title_format";;
#      append)      echo -n "$red_title_format"'`red::title`';;
#      interpolate) echo -n "${red_title_format//\\z/'`red::title`'}";;
#    esac
#    echo -n '\a'
#  fi
#}

red::prompt() {

  if [[ "$red_ps1_orig" == '' ]]; then red_ps1_orig="$PS1"; fi
  red::debug "red_ps1_orig: $red_ps1_orig"

  local prompt_markup='{modules:eol}{user}{reset}@{host} {dir}{eol}{prompt} {reset}'
  while (( $# > 0 )); do
    arg="$1"
    shift
    case "$arg" in
      -p|--prompt)       prompt_markup="$1"; shift ;;
      #-f|--title-format) red_title_format="$1"; shift ;;
      #-t|--title-mode)   red_title_mode="$1"; shift ;;
      -h|--help)         red::help::prompt; return ;;
    esac
  done

  #red_title_mode="${red_title_mode:-prepend}"
  #red::debug "red_title_mode: $red_title_mode"

  #red_title_format="${red_title_format:-\\u@\\h \\w}"
  #red::debug "red_title_format: $red_title_format"

  #IFS='' read -r -d $'\0' title < <(red::title_ps1)
  #red::debug "title: $title"
  red::debug "prompt_markup: $prompt_markup"
  IFS='' read -r -d $'\0' prompt < <(red::render_ps1 "$prompt_markup")
  red::debug "prompt: $prompt"
  export PS1="`red::pre_prompt`$prompt"
  (( err+="$?" ))
  red::debug "PS1: $PS1"

  return $err
}

red "$@"
