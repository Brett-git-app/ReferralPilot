ARG IMAGE=iris-community:2027.1.0AI.109.0
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
