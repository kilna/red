# Kilna's Prompt

## Features

* RedLine - Modular, stylable prompt
  * Collapsible-to-zero status line
* RedEye - ANSI color remapper (similar to base16 project)
* RedAlert - Context-sensitive shell reconfiguration
  * Remap ANSI-colors
  * Change window title
  * Change module styles
  * Change environment variables
  * Change module output
* A robust markup + style system
  * Can output $PS1 compatible strings
  * Can directly output ANSI codes
  * User-defined runtime styles
  * Styles can defined prefix and suffix text
  * Compatible with but not reliant on custom fonts like powerline
* A robust module system
  * Extremely easy to create your own modules
* Pure Bash
  * Bash 3.0 for compatibility with MacOS
  * Minimal subshelling to make it work fast with GitBash
  * No external dependencies (any POSIX compliant system should work)
* Quick to adopt
  * Installable in seconds
  * Simple to add to a .bashrc / .bash_profile
  * Sensible defaults with easy overriding

## To Do

* Refactor modules
* Refactor module integration with styles
  * Resolve colors and other params from environment
* RedAlert sytem

