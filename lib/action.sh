# -*- shell-script -*-
#
#   Copyright (C) 2010 Rocky Bernstein  rocky@gnu.org
#
#   zshdb is free software; you can redistribute it and/or modify it
#   under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2, or (at your
#   option) any later version.
#
#   zshdb is distributed in the hope that it will be useful, but WITHOUT ANY
#   WARRANTY; without even the implied warranty of MERCHANTABILITY or
#   FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
#   for more details.
#   
#   You should have received a copy of the GNU General Public License along
#   with zshdb; see the file COPYING.  If not, write to the Free Software
#   Foundation, 59 Temple Place, Suite 330, Boston, MA 02111 USA.

#================ VARIABLE INITIALIZATIONS ====================#

# Number of actions.
typeset -i _Dbg_action_count=0

# 1/0 if enabled or not
typeset -a  _Dbg_action_enable; _Dbg_action_enable=()

# filename of action $i
typeset -a  _Dbg_action_file; _Dbg_action_file=()

# Line number of action $i
typeset -a _Dbg_action_line; _Dbg_action_line=()

# statement to run when line is hit
typeset -a  _Dbg_action_stmt; _Dbg_action_stmt=()

# Needed because we can't figure out what the max index is and arrays
# can be sparse.
typeset -i  _Dbg_action_max=0

# Maps a resolved filename to a list of action entries.
typeset -A _Dbg_action_file2action; _Dbg_action_file2action=()
 
# Maps a resolved filename to a list of action line numbers in that file
typeset -A _Dbg_action_file2linenos; _Dbg_action_file2linenos=()

# Note: we loop over possibly sparse arrays with _Dbg_brkpt_max by adding one
# and testing for an entry. Could add yet another array to list only 
# used indices. Zsh is kind of primitive.

#========================= FUNCTIONS   ============================#

function _Dbg_save_actions {
  typeset -p _Dbg_action_line         >> $_Dbg_statefile
  typeset -p _Dbg_action_file         >> $_Dbg_statefile
  typeset -p _Dbg_action_enable       >> $_Dbg_statefile
  typeset -p _Dbg_action_stmt         >> $_Dbg_statefile
  typeset -p _Dbg_action_max          >> $_Dbg_statefile
  typeset -p _Dbg_action_file2linenos >> $_Dbg_statefile
  typeset -p _Dbg_action_file2brkpt   >> $_Dbg_statefile

}

# Add actions(s) at given line number of the current file.  $1 is the
# line number or _Dbg_frame_last_lineno if omitted.  $2 is a
# condition to test for whether to stop.
_Dbg_do_action() {
  
  typeset n=${1:-$_Dbg_frame_last_lineno}
  shift

  typeset stmt;
  if [[ -z "$1" ]] ; then
    condition=1
  else 
    condition="$*"
  fi

  typeset filename
  typeset -i line_number
  typeset full_filename

  _Dbg_linespec_setup $n

  if [[ -n $full_filename ]] ; then 
    if (( $line_number ==  0 )) ; then 
      _Dbg_msg "There is no line 0 to set action at."
    else 
      _Dbg_check_line $line_number "$full_filename"
      (( $? == 0 )) && \
	_Dbg_set_action "$full_filename" "$line_number" "$condition" 
    fi
  else
    _Dbg_file_not_read_in $filename
  fi
}

# clear all actions
_Dbg_do_clear_all_actions() {
    (( $# != 0 )) && return 1

    typeset _Dbg_prompt_output=${_Dbg_tty:-/dev/null}
    read $_Dbg_edit -p "Delete all actions? (y/n): " \
	<&$_Dbg_input_desc 2>>$_Dbg_prompt_output
    
    if [[ $REPLY != [Yy]* ]] ; then 
	return 1
    fi
    _Dbg_write_journal_eval "_Dbg_action_enable=()"
    _Dbg_write_journal_eval "_Dbg_action_line=()"
    _Dbg_write_journal_eval "_Dbg_action_file=()"
    _Dbg_write_journal_eval "_Dbg_action_stmt=()"
    _Dbg_write_journal_eval "_Dbg_action_file2action=()"
    _Dbg_write_journal_eval "_Dbg_action_file2linenos=()"
    return 0
}

# delete actions(s) at given file:line numbers. If no file is given
# use the current file.
_Dbg_do_clear_action() {
  typeset -r n=${1:-$_Dbg_frame_last_lineno}

  typeset filename
  typeset -i line_number
  typeset full_filename

  _Dbg_linespec_setup $n

  if [[ -n $full_filename ]] ; then 
    if (( $line_number ==  0 )) ; then 
      _Dbg_msg "There is no line 0 to clear action at."
    else 
      _Dbg_check_line $line_number "$full_filename"
      (( $? == 0 )) && \
	_Dbg_unset_action "$full_filename" "$line_number"
      typeset -r found=$?
      if [[ $found != 0 ]] ; then 
	_Dbg_msg "Removed $found action(s)."
      else 
	_Dbg_msg "Didn't find any actions to remove at $n."
      fi
    fi
  else
    _Dbg_file_not_read_in $filename
  fi
}

# list actions
_Dbg_list_action() {

  if [ ${#_Dbg_action_line[@]} != 0 ]; then
    _Dbg_msg "Actions at following places:"
    typeset -i i

    _Dbg_msg "Num Enb Stmt               file:line"
    for (( i=0; (( i < _Dbg_action_max )) ; i++ )) ; do
      if [[ -n ${_Dbg_action_line[$i]} ]] ; then
	typeset source_file=${_Dbg_action_file[$i]}
	source_file=$(_Dbg_adjust_filename "$source_file")
	_Dbg_printf "%-3d %3d %-18s %s:%s" $i ${_Dbg_action_enable[$i]} \
	  "${_Dbg_action_stmt[$i]}" \
	  $source_file ${_Dbg_action_line[$i]}
      fi
    done
  else
    _Dbg_msg "No actions have been set."
  fi
}

# Internal routine to a set action unconditonally. 

_Dbg_set_action() {
    (( $# != 3 )) && return 1
    typeset source_file
    source_file=$(_Dbg_expand_filename "$1")

    $(_Dbg_is_int $2) || return 1
    typeset -ir lineno=$2
    typeset -r stmt=$3

    # Increment action_max here because we are 1-origin
    ((_Dbg_action_max++))
    ((_Dbg_action_count++))

    _Dbg_action_line[$_Dbg_action_max]=$lineno
    _Dbg_action_file[$_Dbg_action_max]="$source_file"
    _Dbg_action_stmt[$_Dbg_action_max]="$stmt"
    _Dbg_action_enable[$_Dbg_action_max]=1
    
    typeset dq_source_file=$(_Dbg_esc_dq "$source_file")
    typeset dq_stmt=$(_Dbg_esc_dq "stmt")

    _Dbg_write_journal "_Dbg_action_line[$_Dbg_action_max]=$lineno"
    _Dbg_write_journal "_Dbg_action_file[$_Dbg_action_max]=\"$dq_source_file\""
    _Dbg_write_journal "_Dbg_action_stmt[$_Dbg_action_max]=\"$dq_stmt\""
    _Dbg_write_journal "_Dbg_action_enable[$_Dbg_action_max]=1"

    # Add line number with a leading and trailing space. Delimiting the
    # number with space helps do a string search for the line number.
    _Dbg_action_file2linenos[$source_file]+=" $lineno "
    _Dbg_action_file2action[$source_file]+=" $_Dbg_action_max "

    source_file=$(_Dbg_adjust_filename "$source_file")
    _Dbg_msg "Action $_Dbg_action_max set in file ${source_file}, line $lineno."
    _Dbg_write_journal "_Dbg_action_max=$_Dbg_action_max"
    return 0
}

# Internal routine to delete a breakpoint by file/line.
_Dbg_unset_action() {
    (( $# != 2 )) && return 1
    typeset -r  filename="$1"
    $(_Dbg_is_int $2) || return 1
    typeset -i  lineno=$2
    typeset     fullname
    fullname=$(_Dbg_expand_filename "$filename")

    # FIXME: combine with something?
    typeset -a linenos
    eval "linenos=(${_Dbg_action_file2linenos[$fullname]})"
    typeset -a brkpt_nos
    eval "action_nos=(${_Dbg_action_file2action[$fullname]})"

    typeset -i i
    for ((i=0; i < ${#linenos[@]}; i++)); do 
	if (( linenos[i] == lineno )) ; then
	    # Got a match, find breakpoint entry number
	    typeset -i action_num
	    (( action_num = action_nos[i] ))
	    _Dbg_unset_action_arrays $action_num
	    linenos[i]=()  # This is the zsh way to unset an array element
	    _Dbg_action_file2linenos[$fullname]=${linenos[@]}
	    return 1
	fi
    done
    _Dbg_msg "No action found at $filename:$lineno"
    return 0
}

# Routine to a delete actions by entry numbers.
_Dbg_do_action_delete() {
  typeset -r  to_go=$@
  typeset -i  i
  typeset -i  found=0
  
  for del in $to_go ; do 
    case $del in
	[0-9]* )	
	    _Dbg_delete_action_entry $del
            ((found += $?))
	    ;;
	* )
	    _Dbg_msg "Invalid entry number skipped: $del"
    esac
  done
  [[ $found != 0 ]] && _Dbg_msg "Removed $found action(s)."
  return $found
}

# Internal routine to unset the actual breakpoint arrays
# 0 is returned if successful
_Dbg_unset_action_arrays() {
    (( $# != 1 )) && return 1
    typeset -i del=$1
    _Dbg_write_journal_eval "unset _Dbg_action_enable[$del]"
    _Dbg_write_journal_eval "unset _Dbg_action_file[$del]"
    _Dbg_write_journal_eval "unset _Dbg_action_line[$del]"
    _Dbg_write_journal_eval "unset _Dbg_action_stmt[$del]"
    ((_Dbg_action_count--))
    return 0
}
