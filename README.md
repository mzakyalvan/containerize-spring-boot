# README

## Introduction

This document explains how to migrate spring boot based microservices deployment to kubernetes.

Assumptions including :
- Docker daemon installed and running on your machine for testing modified configuration.
- Your multi module maven project follows archetype structure which contains at least `rest-web` executable module.
- Still using java 8.

## Modify Project

Copy or add maven `settings.xml` (by default stored on your `~/.m2/settings.xml`) file into project root directory.

Add `settings.xml` into project's `.gitignore` file, so no credentials leaked into github.

```gitignore
## Maven Settings ##
settings.xml
```

> Ignoring `settings.xml` file means all developers should copy or add this file manually.

Modify scm config element as following. This config enables us to use https for checking out code from github before building docker image and for release proses.

```xml
  <scm>
    <connection>${git.scm.connection}</connection>
    <developerConnection>${git.scm.developer-connection}</developerConnection>
    <url>${git.scm.url}</url>
    <tag>HEAD</tag>
  </scm>
```

Then add scm information into `<properties />` element, so it will be used as default config (Replacing placeholders in `<scm>` config element).

> Please note, `tiket/containerize-spring-boot` is not exists, used here just for example.

```xml
  <properties>
    <java.version>8</java.version>

    <!-- Replace config placeholder on scm configuration, use by default -->
    <git.scm.connection>scm:git:git@github.com:tiket/containerize-spring-boot.git</git.scm.connection>
    <git.scm.developer-connection>scm:git:git@github.com:tiket/containerize-spring-boot.git</git.scm.developer-connection>
    <git.scm.url>https://github.com/tiket/containerize-spring-boot.git</git.scm.url>
  </properties>
```

Add following profiles in project's reactor/main `pom.xml` file

```xml
  <profiles>
    <profile>
      <id>eleven</id>
      <activation>
        <jdk>11</jdk>
      </activation>
      <properties>
        <java.version>11</java.version>
      </properties>
    </profile>
    <profile>
      <id>docker</id>
      <activation>
        <activeByDefault>false</activeByDefault>
      </activation>
      <properties>
        <git.scm.connection>scm:git:https://github.com/tiket/containerize-spring-boot.git</git.scm.connection>
        <git.scm.developer-connection>scm:git:https://github.com/tiket/containerize-spring-boot.git</git.scm.developer-connection>
        <git.scm.url>https://github.com/tiket/containerize-spring-boot.git</git.scm.url>
      </properties>
    </profile>
  </profiles>
```

Please note, profile with name `eleven` just adding new properties to override `java.version` properties (from 8 to 11), activated/enabled by default when we use jdk11. Profile with name `docker` overrides properties for scm configuration, using github's https endpoint, add `-P docker` flag to activate this profile.

Then, add following plugin in pom file of rest-web module with intent to simplify jar file copy when building image.

```xml
  <build>
    <plugins>
      <!-- Other plugin omitted -->
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-antrun-plugin</artifactId>
        <executions>
          <execution>
            <phase>post-integration-test</phase>
            <goals>
              <goal>run</goal>
            </goals>
            <configuration>
              <target>
                <copy overwrite="true"
                  file="${project.build.directory}/${project.artifactId}-${project.version}.jar"
                  toFile="${project.build.directory}/application.jar" />
              </target>
            </configuration>
          </execution>
        </executions>
      </plugin>
    </plugins>
  </build>
```

Last file to modify, change `logback-spring.xml` so that all logs will be appended into stdout or console (Better backup your current config file first).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration scan="true">
  <include resource="org/springframework/boot/logging/logback/defaults.xml"/>

  <property resource="application.properties"/>
  <property resource="bootstrap.properties" />

  <springProperty scope="context" name="applicationName" source="spring.application.name"/>

  <property name="CONSOLE_LOG_PATTERN"
    value="%clr(%d{yyyy-MM-dd HH:mm:ss.SSS}){faint} %clr(${LOG_LEVEL_PATTERN:-%5p}) %clr(${PID:- }){magenta} %clr(---){faint} %clr([%15.15t]){faint} %clr(%-40.40logger{39}){cyan} %clr(:){faint} %m%n${LOG_EXCEPTION_CONVERSION_WORD:-%wEx}"/>
  <property name="STDOUT_LOG_PATTERN"
    value="[%level] %date{YYYY-MM-dd HH:mm:ss.SSS} [${applicationName}][%X{X-B3-TraceId:-}][%X{X-B3-SpanId:-}] [%thread] %logger{10} %msg%n" />

  <appender class="ch.qos.logback.core.ConsoleAppender" name="STDOUT">
    <encoder>
      <pattern>${STDOUT_LOG_PATTERN}</pattern>
    </encoder>
  </appender>

  <logger name="com.tiket.tix.train" level="DEBUG" additivity="false">
    <appender-ref ref="STDOUT"/>
  </logger>
  <logger name="reactor.netty.http.client" level="TRACE" additivity="false">
    <appender-ref ref="STDOUT"/>
  </logger>

  <root level="INFO">
    <appender-ref ref="STDOUT"/>
  </root>
</configuration>
```

## Create Dockerfile

We use multistage docker build, each deploy environment (local, development and staging) using different stages determined by `BUILD_ENV` build-arg.

```dockerfile
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
```

## Building Image

For building image in local or developer machine, run `mvn clean verify` first, then execute following command from project root directory.

> To enable skipping unused stages when building docker image (remember we use multistage dockerfile), we have to set `DOCKER_BUILDKIT=1` on every `docker build` command. Or you can configure to enable buildkit feature by default on docker daemon configuration.

```shell
$ DOCKER_BUILDKIT=1 docker build -t containerize-spring-boot:latest --build-arg BUILD_ENV=local .
```

Verify built image, `docker image list`.

## Running Image

This section we will try to run the image. For simplicity reason, we will run it on Docker instead of kubernetes, rest assuring our image crafted correctly.

```shell
$ docker run --publish 8080:8080 containerize-spring-boot
```

## Create Jenkinsfile

Before pushing your configuration to github, create new `Jenkinsfile.dev`

```
podTemplate(
  containers: [
    containerTemplate(name: 'maven', image: 'maven:3.6.3-jdk-11', ttyEnabled: true, command: 'cat', args: '')
  ],
  volumes: [
    persistentVolumeClaim(claimName: 'nfs-jenkins-storage-pvc', mountPath: '/var/maven/repository')
  ],
  serviceAccount: 'jenkins-service-account'
)
{
  node(POD_LABEL) {
    container('maven') {
      checkout scm
      stage('Build and Test') {
        withSonarQubeEnv(installationName: 'tiket-sonar') {
          configFileProvider([configFile(fileId: 'MAVEN_SETTINGS', variable: 'MAVEN_SETTINGS')]) {
            sh "mvn -s ${MAVEN_SETTINGS} clean jacoco:prepare-agent install sonar:sonar"
          }
        }
      }
      stage("Quality Gate") {
        timeout(time: 1, unit: 'MINUTES') {
          sleep(45)
            def qg = waitForQualityGate()
              if (qg.status != 'OK') {
                error "Pipeline aborted due to quality gate failure: ${qg.status}"
              }
        }
      }
    }
  }
}
```