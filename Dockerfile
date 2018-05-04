FROM quay.io/mojodna/gdal:v2.3.0beta1
MAINTAINER Seth Fitzsimmons <seth@mojodna.net>

ARG http_proxy

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
    bc \
    ca-certificates \
    curl \
    git \
    jq \
    nfs-common \
    parallel \
    python-pip \
    python-wheel \
    python-setuptools \
    unzip \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/marblecutter-tools

COPY requirements.txt /opt/marblecutter-tools/requirements.txt

RUN pip install cython

RUN pip install -r requirements.txt && \
  rm -rf /root/.cache

COPY bin/* /opt/marblecutter-tools/bin/

RUN ln -s /opt/marblecutter-tools/bin/* /usr/local/bin/ && \
  mkdir -p /efs

ENV CPL_VSIL_CURL_ALLOWED_EXTENSIONS .vrt,.tif,.tiff,.ovr,.msk,.jp2,.img,.hgt
ENV GDAL_DISABLE_READDIR_ON_OPEN TRUE
ENV VSI_CACHE TRUE
ENV VSI_CACHE_SIZE 536870912
