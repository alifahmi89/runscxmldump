#!/bin/bash

# Dump seiscomp3 events, get picking informations
# Author   : Ali Fahmi
# Created  : 2019-08-23
# Modified : 2022-01-27

eventtype=(UNKNOWN EXPLOSION GASBURST VTA VTB LF MP TREMOR ROCKFALL AWANPANAS LAHAR TECT TECLOC TELE TPHASE SOUND ANTHROP AUTO COMMENT ALL)

if [ "$#" -lt 3 ];
then
    	echo -e "Dump seiscomp3 events, get picking informations\n"
    	echo "Syntax:"
        echo "$0 start_date end_date event_type"
        echo "$0 2020-08-01 2020-08-31 VTA"
	echo -e "\nevent_type:\n$(echo ${eventtype[@]})"
        exit 1
fi

cfgfile=$(basename ${0%.*}).conf

if [ ! -f $cfgfile ];
then
	echo "$cfgfile file does not exists."
	exit 1
else
	user=$(cat $cfgfile | grep wouser | cut -d= -f2) 
	pass=$(cat $cfgfile | grep wopass | cut -d= -f2)

	if [ -z "$user" ] || [ -z "$pass" ];
	then
		echo "$cfgfile file does not contain webobs user or password."
		exit 1
	fi
fi

home=$(dirname $(realpath $0))

mc3d=$home/mc3
xmld=$home/xml

get_mc3 ()
{
	local start=$1
	local end=$2

	for a in ${eventtype[@]};
	do
		if [ "$a" == "$3" ];
		then
			type=$a
			break
		fi
	done

	if [ "$type" == "" ];
	then
		printf "Invalid event type: $3\n"
		exit 1
	fi

	tgl1="$start"
	y1=${tgl1:0:4}
	m1=${tgl1:5:2}
	d1=${tgl1:8:2}
	h1=00

	tgl2="$end"
	y2=${tgl2:0:4}
	m2=${tgl2:5:2}
	d2=${tgl2:8:2}
	h2=00

	url="http://localhost/cgi-bin/mc3.pl?y1=${y1}&m1=${m1}&d1=${d1}&h1=${h1}&y2=${y2}&m2=${m2}&d2=${d2}&h2=${h2}&type=${type}&duree=ALL&ampoper=eq&amplitude=ALL&obs=&locstatus=0&located=0&mc=MC3&dump=bul&hideloc=0&newts="

	local event=$(curl --silent -JL -u $user:$pass $url)

	output=$mc3d/mc3_${start}_${end}_${type}.txt	
	echo "$event" > $output
}

et=$3
printf "==== $et ====\n"
get_mc3 $1 $2 $et

if [ "$(cat $output | grep -n "#" | tail -n 1 | cut -d":" -f1)" -lt 3 ];
then
	printf "Event tidak ditemukan.\n\n"
	rm $output
else
	outputid=${output%.*}_id.txt
	> $outputid

	while IFS= read -r line; 
	do 
		scid=$(echo $line | cut -d\; -f11 | cut -c 4-)
		[ ! -z "$scid" ] && echo $scid >> $outputid
	done < $output
	sed -i 1,2d $outputid

	printf "Event from MC3 downloaded.\nOutput file: $output\nSeiscomp ID: $outputid\n\n"

	# dump sc3 database to xml, then extract the data
	printf "Dumping seiscomp3 events to xml & txt file...\n"
	xmlout=$xmld/${1}_${2}_${type}
	if [ -d xmlout ];
	then
		rm -rf $xmlout
	fi
	mkdir -p $xmlout

	while IFS= read -r scid; 
        do
		pickxml=$xmlout/${scid}.xml
		picktxt=$xmlout/${scid}.txt
		uniqtxt=$xmlout/${scid}.uniq
		scdb=mysql://sysop:sysop@localhost/seiscomp3

		# dump sc3db to xml
                scxmldump -fPq -E $scid -o $pickxml -d $scdb

		# extract data from xml
		if [ -f $pickxml ];
		then
			sed -i '2s/.*/<seiscomp>/' $pickxml # edit header xml biar bisa dibaca xmlstarlet
			originpath=//seiscomp/EventParameters/origin
			pickpath=//seiscomp/EventParameters/pick

			originstr=$(xmlstarlet sel -t -m $originpath -v "concat(time/value,';',magnitude/magnitude/value,';',magnitude/magnitude/uncertainty,';',depth/value,';',depth/uncertainty,';',latitude/value,';',latitude/uncertainty,';',longitude/value,';',longitude/uncertainty)" -n $pickxml | tail -n 1)
			# contoh: 2020-08-10T23:57:08.21Z;2.813365405;0.1286118746;-2.03;0.1;-7.537166667;0.07071067812;110.4506667|0.07071067812
			echo "$originstr" > $picktxt

			# contoh: MEPET;2020-08-10T23:57:09.428556Z;0.009999999776;manual
			xmlstarlet sel -t -m $pickpath -s A:T:- creationInfo/creationTime -v "concat(waveformID/@stationCode,';',phaseHint,';',time/value,';',time/upperUncertainty,';',evaluationMode)" -n $pickxml | grep manual >> $picktxt
	#fi

			# do something to take only the last picking
			echo "$originstr" > $uniqtxt

			stalist=( $(while IFS= read -r pick; do echo $pick | cut -d";" -f1; done < <(tail -n +2 $picktxt) | sort -u) ) # ( ) make strings into array
			for sta in "${stalist[@]}"; 
			do 
				newentry=$(cat $picktxt | grep "$sta" | tail -n 1)
				echo $newentry >> $uniqtxt
			done
			printf "$uniqtxt\n"	
		fi
        done < $outputid	

	# format the output & put them into single file
	allpicks=$xmlout/picks_${1}_${2}_${type}.txt
	echo "Number;event_time;mag;mag_error;depth;depth_error;lat;lat_error;long;long_error" > $allpicks
	echo -e "STA;phase;picktime;error\n" >> $allpicks

	cd $xmlout
	urut=0
	echo ""

	for pickfile in $(ls bpptkg*uniq);
	do
		# baca header
		printf "Extracting $pickfile\n"
		urut=$(( urut + 1 ))
		header="$(sed '1q;d' $pickfile)"
		tgl=$(echo $header | cut -d"T" -f1)
		#jam=$(echo $header | cut -d"T" -f2 | cut -d";" -f1 | cut -c -11)
		jam=$(echo $header | cut -d"T" -f2 | cut -d"Z" -f1)
		mag=$(printf '%.3f' $(echo $header | cut -d";" -f2)) # 3 digit di belakang koma
		mag_err=$(printf '%.3f' $(echo $header | cut -d";" -f3)) 
		depth=$(printf '%.2f' $(echo $header | cut -d";" -f4))
		depth_err=$(printf '%.2f' $(echo $header | cut -d";" -f5))
		lat=$(printf '%.4f' $(echo $header | cut -d";" -f6)) 
		lat_err=$(printf '%.4f' $(echo $header | cut -d";" -f7)) 
		lon=$(printf '%.4f' $(echo $header | cut -d";" -f8))
		lon_err=$(printf '%.4f' $(echo $header | cut -d";" -f9)) 

		echo "$urut;$tgl $jam;$mag;$mag_err;$depth;$depth_err;$lat;$lat_err;$lon;$lon_err" >> $allpicks

		# baca hasil pick (mulai dari baris kedua)
		while IFS= read -r pick;
		do
			sta=$(echo $pick | cut -d";" -f1)
			phase=$(echo $pick | cut -d";" -f2)
			pickdate=$(echo $pick | cut -d";" -f3 | cut -d"T" -f1)
			picktime=$(echo $pick | cut -d";" -f3 | cut -d"T" -f2 | sed 's/Z//g')
			picksec=$(printf '%.2f' $(echo $picktime | cut -d":" -f3))
			picktime=$(echo $picktime | cut -d":" -f1-2)":"$picksec
			pick_err=$(printf '%.2f' $(echo $pick | cut -d";" -f4))

			echo "$sta;$phase;$pickdate $picktime;$pick_err" >> $allpicks
		done < <(tail -n +2 $pickfile)	
		echo "" >> $allpicks
	done

	printf "\nAll picks saved to $allpicks\n"
fi
