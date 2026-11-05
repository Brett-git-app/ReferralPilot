ARG IMAGE=iris-community:2026.3.0AI.154.0
FROM ${IMAGE}

WORKDIR /home/irisowner/dev
COPY . /home/irisowner/dev

ENV IRISUSERNAME=_SYSTEM
ENV IRISPASSWORD=SYS
ENV IRISNAMESPACE=IRISAPP

RUN iris start IRIS && \
    iris session IRIS < /home/irisowner/dev/iris.script && \
    iris stop IRIS quietly

EXPOSE 1972 52773
