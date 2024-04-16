#!/bin/sh
#Simple voz-ser monitor script
#
#

if [ $# -lt 1 ] ; then
   echo "usage: $0 <config.json>"
   exit 1
fi

# Parse config.json
# {
#   "exe": "<path to voz-ser exec>"
#   "dev": "<serial device>"
#   "models": "<path to models>"
#   "wakewords": "<path to wakewords>"
#   "led": "<gpiochip:number>"
#   "int": "<gpiochip:number>"
#   "pidfile": "<path to the pidfgile>"
#   "retry": <retry count>
#}

# utility to read configuration element
read_cnf() {
   local key=$1
   local file=$2
   local def_value=$3

   local r=$(jq -r ".${key}" ${file})
   [ "${r}" = "null" ] && r="$def_value"
   echo "${r}"
}

vs_exe=$(read_cnf "exe" "$1" "/opt/voz/voz-ser")
vs_dir=$(realpath $(dirname "$vs_exe"))
dev=$(read_cnf "dev" "$1" "/dev/ttyS1")
dev="--device ${dev}"
models=$(read_cnf "models" "$1" "")
[ -n "$models" ] && models="--basemodeldir ${models}"
wwmodels=$(read_cnf "wakewords" "$1" "")
[ -n "$wwmodels" ] && wwmodels="--wwmodeldir ${wwmodels}"
int=$(read_cnf "int" "$1" "")
[ -n "$int" ] && int="--int ${int}"
led=$(read_cnf "led" "$1" "")
[ -n "$led" ] && led="--led ${led}"

pidfile=$(read_cnf "pidfile" "$1" "/run/voz-ser.pid")
retry=$(read_cnf "retry" "$1" "3")


echo "$0 started. Will minitor the following process:"
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$vs_dir
cmd="$vs_exe $dev $models $wwmodels $int $led"
echo ">>> '$cmd'"
echo ">>> pidfile:$pidfile retry:$retry, LD_LIBRARY_PATH=$LD_LIBRARY_PATH"

# Monitor loop
voz_pid=0
run_it=1
ret=0

while [ $run_it -eq 1 ] ; do

   if [ $voz_pid -eq 0 ] ; then
      printf "Starting voz-ser..."
      $cmd &
      vod_pid=$!
      if [ $vod_pid -eq 0 ] ; then
         ret=1
         echo "failed to start '$cmd'"
         break
      fi
      echo "$voz_pid" > $pidfile
      echo "[$voz_pid]"
   fi
   waitpid $voz_pid
   

   ret=$?
   rm $pidfile 
   voz_pid=0

   case $ret in

      # Normal exit or requested exit
      0 | 6)
            run_it=0
            ret=0
            ;;
      # Restart
      1)
         sleep 3
         continue
         ;;

      # Restart With retry
      2)
         sleep 5
         retry=$((retry-1))
         [ $retry -lt 1 ] && run_it=0
         ;;
      
      # Other
      *)
         run_it=0
         ;;
   esac


done

[ -f "$pidfile" ] && rm "$pidfile"

echo "$0 finished code=>$ret."
exit $ret
