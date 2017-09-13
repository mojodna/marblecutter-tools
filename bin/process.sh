#!/usr/bin/env bash

input=$1
output=$2
# target size in KB
THUMBNAIL_SIZE=${THUMBNAIL_SIZE:-300}
TILER_BASE_URL=${TILER_BASE_URL:-http://tiles.openaerialmap.org}
export AWS_S3_ENDPOINT_SCHEME=${AWS_S3_ENDPOINT_SCHEME:-https://}
export AWS_S3_ENDPOINT=${AWS_S3_ENDPOINT:-s3.amazonaws.com}

set -euo pipefail

to_clean=()

function cleanup() {
  for f in ${to_clean[@]}; do
    rm -f "${f}"
  done
}

function cleanup_on_failure() {
  s3_outputs=(${output}.tif ${output}.tif.msk ${output}.json ${output}.png)

  set +e
  for x in ${s3_outputs[@]}; do
    aws s3 rm --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} $x 2> /dev/null
  done
  set -e

  cleanup
}

if [[ -z "$input" || -z "$output" ]]; then
  # input is an HTTP-accessible GDAL-readable image
  # output is an S3 URI w/o extensions
  # e.g.:
  #   bin/process.sh \
  #   http://hotosm-oam.s3.amazonaws.com/uploads/2016-12-29/58655b07f91c99bd00e9c7ab/scene/0/scene-0-image-0-transparent_image_part2_mosaic_rgb.tif \
  #   s3://oam-dynamic-tiler-tmp/sources/58655b07f91c99bd00e9c7ab/0/58655b07f91c99bd00e9c7a6
  >&2 echo "usage: $(basename $0) <input> <output basename>"
  exit 1
fi

set +u

# attempt to load credentials from an IAM profile if none were provided
if [[ -z "$AWS_ACCESS_KEY_ID"  || -z "$AWS_SECRET_ACCESS_KEY" ]]; then
  set +e

  role=$(curl -sf --connect-timeout 1 http://169.254.169.254/latest/meta-data/iam/security-credentials/)
  credentials=$(curl -sf --connect-timeout 1 http://169.254.169.254/latest/meta-data/iam/security-credentials/${role})
  export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<< $credentials)
  export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<< $credentials)
  export AWS_SESSION_TOKEN=$(jq -r .Token <<< $credentials)

  set -e
fi

# mount an EFS volume if requested and use that as TMPDIR
if [[ ! -z "$EFS_HOST" ]]; then
  set +e
  mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 ${EFS_HOST}:/ /efs
  set -e

  export CPL_TMPDIR=/efs
  export TMPDIR=/efs
fi

set -u

trap cleanup EXIT
trap cleanup_on_failure INT
trap cleanup_on_failure ERR

__dirname=$(cd $(dirname "$0"); pwd -P)
PATH=$__dirname:$PATH
filename=$(basename $input)
base=$(mktemp)
to_clean+=($base)
source="${base}.${filename}"
intermediate=${base}-intermediate.tif
to_clean+=($intermediate)
gdal_output=$(sed 's|s3://\([^/]*\)/|/vsis3/\1/|' <<< $output)
tiler_url=$(sed "s|s3://[^/]*|${TILER_BASE_URL}|" <<< $output)

>&2 echo "Processing ${input} into ${output}.{json,tif,tif.msk}..."

# 0. download source (if appropriate; non-archived, S3-hosted sources will be
# transcoded using VSI)

if [[ "$input" =~ ^s3:// ]] && \
   [[ "$input" =~ \.zip$ || "$input" =~ \.tar\.gz$ ]]; then
  >&2 echo "Downloading $input (archive) from S3..."
  aws s3 cp --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} $input $source
  to_clean+=($source)
elif [[ "$input" =~ s3\.amazonaws\.com ]] && \
     [[ "$input" =~ \.zip$ || "$input" =~ \.tar\.gz$ ]]; then
  >&2 echo "Downloading $input (archive) from S3 over HTTP..."
  curl -sfL $input -o $source
  to_clean+=($source)
elif [[ "$input" =~ ^https?:// ]]; then
  >&2 echo "Downloading $input..."
  curl -sfL $input -o $source
  to_clean+=($source)
else
  source=$input
fi

# 1. transcode + generate overviews
transcode.sh $source $intermediate

# keep local sources
if [[ "$input" =~ ^(s3|https?):// ]]; then
  rm -f $source
fi

# 6. create thumbnail
>&2 echo "Generating thumbnail..."
thumb=${base}.png
to_clean+=($thumb ${thumb}.aux.xml ${thumb}.msk)
info=$(rio info $intermediate 2> /dev/null)
count=$(jq .count <<< $info)
height=$(jq .height <<< $info)
width=$(jq .width <<< $info)
target_pixel_area=$(bc -l <<< "$THUMBNAIL_SIZE * 1000 / 0.75")
ratio=$(bc -l <<< "sqrt($target_pixel_area / ($width * $height))")
target_width=$(printf "%.0f" $(bc -l <<< "$width * $ratio"))
target_height=$(printf "%.0f" $(bc -l <<< "$height * $ratio"))
gdal_translate -of png $intermediate $thumb -outsize $target_width $target_height

# 5. create footprint
>&2 echo "Generating footprint..."
info=$(rio info $intermediate)
resolution=$(get_resolution.py $intermediate)

# resample using 'average' so that rescaled pixels containing _some_ values
# don't end up as NODATA
gdalwarp -r average \
  -ts $[$(jq -r .width <<< $info) / 100] $[$(jq -r .height <<< $info) / 100] \
  -srcnodata $(jq -r .nodata <<< $info) \
  $intermediate ${intermediate/.tif/_small.tif}

footprint=${base}.json
to_clean+=($footprint)

small=${intermediate/.tif/_small.tif}
to_clean+=($small)
rio shapes --mask --as-mask --precision 6 ${small} | \
  rio_shapes_to_multipolygon.py --argfloat resolution=${resolution} --argstr filename="$(basename $output).tif" > $footprint

if [[ "$output" =~ ^s3:// ]]; then
  >&2 echo "Uploading..."
  aws s3 cp --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} $intermediate ${output}.tif

  aws s3 cp --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} $footprint ${output}.json

  aws s3 cp --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} $thumb ${output}.png

  if [ -f ${intermediate}.msk ]; then
    # 3. upload mask
    >&2 echo "Uploading mask..."
    aws s3 cp --endpoint-url ${AWS_S3_ENDPOINT_SCHEME}${AWS_S3_ENDPOINT} ${intermediate}.msk ${output}.tif.msk
  fi
else
  mv $intermediate ${output}.tif
  mv $footprint ${output}.json
  mv $thumb ${output}.png
  mv ${intermediate}.msk ${output}.tif.msk
fi

# TODO call web hooks
# 1. metadata
#   a. resolution
#   b. dimensions
#   c. bounds
#   d. band count
#   e. file size
#   f. band types
#   g. footprint
# 2. thumbnail

rm -f ${intermediate}*

>&2 echo "Done."
