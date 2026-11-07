ARG BASE_LABEL=latest

FROM mpioperator/openmpi-builder:${BASE_LABEL} AS builder
ARG IO500_REF=io500-sc26
ARG IOR_REF=

WORKDIR /BUILD
RUN apt update && apt install -y \
    autoconf automake bash curl git pkg-config m4 libtool make \
    gcc gfortran libaio-dev wget unzip

# IO500_REF: io500 tag (default io500-sc26); IOR_REF: optional IOR commit (empty = what prepare.sh fetches)
RUN git clone https://github.com/IO500/io500.git \
    && cd io500 && if [ -n "${IO500_REF}" ]; then git checkout ${IO500_REF}; fi
RUN cd io500 && ./prepare.sh \
    && if [ -n "${IOR_REF}" ]; then cd build/ior && git fetch -q origin && git checkout ${IOR_REF} \
       && ./bootstrap && ./configure --with-mpiio && make -j && cd ../.. && make clean && make -j; fi \
    && (cd /BUILD/io500 && git describe --tags; cd build/ior && git rev-parse HEAD) > /BUILD/io500/VERSIONS

FROM mpioperator/openmpi:${BASE_LABEL}

COPY --from=builder /BUILD/io500 /io500
