ARG BUILD_ENV=local

FROM maven:3.6.3-jdk-11 AS maven

## Build in developer's local machine, assume jar file already created (mvn clean verify).
FROM maven AS build-local
COPY ./rest-web/target/application.jar /build/application.jar

## Build in development environment
FROM maven AS build-develop
COPY settings.xml /root/.m2/settings.xml
COPY . /sources
WORKDIR /build
RUN mvn -f /sources/pom.xml clean verify
RUN cp /sources/rest-web/target/application.jar ./application.jar

## Build in staging environment
FROM maven AS build-staging
COPY settings.xml /root/.m2/settings.xml
COPY . /sources
WORKDIR /build
RUN mvn -f /sources/pom.xml -P docker -B clean release:clean release:prepare release:perform
RUN cp /sources/target/checkout/rest-web/target/application.jar ./application.jar

## Create temporary image as source for copying application.jar
FROM build-${BUILD_ENV} AS builder

## Create final docker image.
FROM asia-southeast1-docker.pkg.dev/tk-dev-micro/base-image/distroless-java11
WORKDIR /app
COPY --from=builder build/application.jar ./
ENTRYPOINT ["java", "-jar", "application.jar"]