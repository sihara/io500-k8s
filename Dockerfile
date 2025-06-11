ARG BASE_LABEL=latest

FROM mpioperator/openmpi-builder:${BASE_LABEL} AS builder

WORKDIR /BUILD
RUN apt update && apt install -y \
    autoconf automake bash curl git pkg-config m4 libtool make \
    gcc gfortran libaio-dev wget unzip

RUN git clone https://github.com/IO500/io500.git \
    && cd io500 && ./prepare.sh

FROM mpioperator/openmpi:${BASE_LABEL}

COPY --from=builder /BUILD/io500 /io500
