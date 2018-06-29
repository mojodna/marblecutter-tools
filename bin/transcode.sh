#!/usr/bin/env bash

input=$1
output=$2
callback_url=$3

if [[ ! -z "$DEBUG" ]]; then
  set -x
fi

set -euo pipefail

function update_status() {
  set +u

  if [[ ! -z "$callback_url" ]]; then
    local status=$1
    local message=$2
    cat <<EOF | curl -s -X POST -d @- -H "Content-Type: application/json" "${callback_url}"
{
  "status": "${status}",
  "message": "${message}"
}
EOF
  fi

  set -u
}

function cleanup_transcode_on_failure() {
  # prevent double-cleanup
  if [[ $failed -eq 0 ]]; then
    failed=1

    if [[ ${#to_clean[@]} -gt 0 ]]; then
      for f in ${to_clean[@]}; do
        rm -f "${f}"
      done
    fi
  fi
}

if [ -z $input ]; then
  >&2 echo "usage: $(basename $0) <input> [output]"
  exit 1
fi

if [ -z $output ]; then
  output=$(basename $input)
fi

ext=${input##*.}
failed=0
to_clean=()

if [[ "$ext" == "zip" ]]; then
  # assume it's a zipped TIFF
  inner_source=$(unzip -ql ${input} | grep "tif$\|dem$" | head -1 | awk '{print $4}')

  if [[ -z "$inner_source" ]]; then
    >&2 echo "Could not find a TIFF inside ${input}"
    exit 1
  fi

  input="zip://${input}!${inner_source}"
elif [[ "$input" =~ \.tar\.gz$ ]]; then
  inner_source=$(tar ztf ${input} | grep "tif$" | head -1)

  if [[ -z "$inner_source" ]]; then
    >&2 echo "Could not find a TIFF inside ${input}"
    exit 1
  fi

  input="tar://${input}!${inner_source}"
elif [[ "$input" =~ \.tar$ ]]; then
  inner_source=$(tar tf ${input} | grep "tif$" | head -1)

  if [[ -z "$inner_source" ]]; then
    >&2 echo "Could not find a TIFF inside ${input}"
    exit 1
  fi

  input="tar://${input}!${inner_source}"
fi

trap cleanup_transcode_on_failure INT
trap cleanup_transcode_on_failure ERR

>&2 echo "Transcoding ${input}..."

info=$(rio info $input 2> /dev/null)
count=$(jq .count <<< $info)
dtype=$(jq -r .dtype <<< $info)
height=$(jq .height <<< $info)
width=$(jq .width <<< $info)
zoom=$(get_zoom.py $input)
colorinterp=$(jq .colorinterp <<< $info)
overviews=""
mask=""
opts=""
overview_opts=""
bands=""
intermediate=$(mktemp --suffix ".tif")
to_clean+=($intermediate ${intermediate}.msk ${intermediate}.aux.xml)

# update input path for GDAL now that rasterio has read it
if [[ $input =~ "http://" ]] || [[ $input =~ "https://" ]]; then
  input="/vsicurl/$input"
elif [[ $input =~ "s3://" ]]; then
  input=$(sed 's|s3://\([^/]*\)/|/vsis3/\1/|' <<< $input)
elif [[ $input =~ "zip://" ]]; then
  input=$(sed 's|zip://\(.*\)!\(.*\)|/vsizip/\1/\2|' <<< $input)
elif [[ $input =~ "tar://" ]]; then
  input=$(sed 's|tar://\(.*\)!\(.*\)|/vsitar/\1/\2|' <<< $input)
fi


if [ "$count" -eq 4 ] && [ "$dtype" == "uint8" ] && [ "$(jq -r ".[3]" <<< $colorinterp)" == "alpha" ]; then
  mask="-mask 4"
else
  mask="-mask mask"
fi

if ( [[ "$count" -eq 3 ]] || [[ "$count" -eq 4 ]] ) && [[ "$dtype" == "uint8" ]]; then
  opts="-co COMPRESS=JPEG -co PHOTOMETRIC=YCbCr"
  overview_opts="--config COMPRESS_OVERVIEW JPEG --config PHOTOMETRIC_OVERVIEW YCbCr"
elif [[ "$dtype" =~ "float" ]]; then
  opts="-co COMPRESS=DEFLATE -co PREDICTOR=3 -co ZLEVEL=9"
  overview_opts="--config COMPRESS_OVERVIEW DEFLATE --config PREDICTOR_OVERVIEW 3 --config ZLEVEL_OVERVIEW 9"
else
  opts="-co COMPRESS=DEFLATE -co PREDICTOR=2 -co ZLEVEL=9"
  overview_opts="--config COMPRESS_OVERVIEW DEFLATE --config PREDICTOR_OVERVIEW 2 --config ZLEVEL_OVERVIEW 9"
fi

for b in $(seq 1 $count); do
  if [ "$dtype" == "uint8" ] && [ "$(jq -r ".[3]" <<< $colorinterp)" == "alpha" ]; then
    >&2 echo "Skipping alpha band; it's being treated as a mask"
  else
    bands="$bands -b $b"
  fi
done

>&2 echo "Transcoding ${count} band(s)..."
update_status status "Transcoding ${count} band(s)..."
# TODO make timeout configurable
timeout --foreground 2h gdal_translate \
  -q \
  -stats \
  $bands \
  $mask \
  -co TILED=yes \
  -co BLOCKXSIZE=512 \
  -co BLOCKYSIZE=512 \
  -co NUM_THREADS=ALL_CPUS \
  -co BIGTIFF=IF_SAFER \
  --config GDAL_TIFF_INTERNAL_MASK YES \
  $opts \
  $input $intermediate

for z in $(seq 1 $zoom); do
  overviews="${overviews} $[2 ** $z]"

  # stop when overviews fit within a single block (even if they cross)
  if [ $[$height / $[2 ** $[$z]]] -lt 512 ] && [ $[$width / $[2 ** $[$z]]] -lt 512 ]; then
    break
  fi
done

>&2 echo "Adding overviews..."
update_status status "Adding overviews..."
timeout --foreground 8h gdaladdo \
  -q \
  -r lanczos \
  --config GDAL_TIFF_OVR_BLOCKSIZE 512 \
  --config TILED_OVERVIEW yes \
  --config BLOCKXSIZE_OVERVIEW 512 \
  --config BLOCKYSIZE_OVERVIEW 512 \
  --config NUM_THREADS_OVERVIEW ALL_CPUS \
  $overview_opts \
  $intermediate \
  $overviews

>&2 echo "Creating cloud-optimized GeoTIFF..."
update_status status "Creating cloud-optimized GeoTIFF..."
timeout --foreground 2h gdal_translate \
  -q \
  -stats \
  $bands \
  -co TILED=yes \
  -co BLOCKXSIZE=512 \
  -co BLOCKYSIZE=512 \
  -co NUM_THREADS=ALL_CPUS \
  -co BIGTIFF=IF_SAFER \
  $opts \
  $overview_opts \
  -co COPY_SRC_OVERVIEWS=YES \
  --config GDAL_TIFF_INTERNAL_MASK YES \
  --config GDAL_TIFF_OVR_BLOCKSIZE 512 \
  $intermediate $output

rm -f $intermediate ${intermediate}.aux.xml
