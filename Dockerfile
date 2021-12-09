FROM openjdk:8-bullseye

ADD sources.list /etc/apt/sources.list

RUN ln -fs /bin/bash /bin/sh && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian bullseye stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y git curl gpg unzip libfreetype6 libfontconfig1 procps wget docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

ENV LANG C.UTF-8

# amd64/arm64/arm/386
ARG TARGETARCH
ARG COMMIT_SHA
ARG GIT_LFS_VERSION=3.0.2

# required for multi-arch support, revert to package cloud after:
# https://github.com/git-lfs/git-lfs/issues/4546
COPY git_lfs_pub.gpg /tmp/git_lfs_pub.gpg
RUN GIT_LFS_ARCHIVE="git-lfs-linux-${TARGETARCH}-v${GIT_LFS_VERSION}.tar.gz" \
    GIT_LFS_RELEASE_URL="https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/${GIT_LFS_ARCHIVE}"\
    set -x; curl --fail --silent --location --show-error --output "/tmp/${GIT_LFS_ARCHIVE}" "${GIT_LFS_RELEASE_URL}" && \
    curl --fail --silent --location --show-error --output "/tmp/git-lfs-sha256sums.asc" https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_VERSION}/sha256sums.asc && \
    gpg --no-tty --import /tmp/git_lfs_pub.gpg && \
    gpg -d /tmp/git-lfs-sha256sums.asc | grep "${GIT_LFS_ARCHIVE}" | (cd /tmp; sha256sum -c ) && \
    mkdir -p /tmp/git-lfs && \
    tar xzvf "/tmp/${GIT_LFS_ARCHIVE}" -C /tmp/git-lfs && \
    bash -x /tmp/git-lfs/install.sh && \
    rm -rf /tmp/git-lfs*


ARG user=jenkins
ARG group=jenkins
ARG uid=1000
ARG gid=1000
ARG http_port=8080
ARG agent_port=50000
ARG JENKINS_HOME=/var/jenkins_home
ARG REF=/usr/share/jenkins/ref

ENV JENKINS_HOME $JENKINS_HOME
ENV JENKINS_SLAVE_AGENT_PORT ${agent_port}
ENV REF $REF

# Jenkins is run with user `jenkins`, uid = 1000
# If you bind mount a volume from the host or a data container,
# ensure you use the same uid
RUN mkdir -p $JENKINS_HOME \
  && chown ${uid}:${gid} $JENKINS_HOME \
  && groupadd -g ${gid} ${group} \
  && useradd -d "$JENKINS_HOME" -u ${uid} -g ${gid} -m -s /bin/bash ${user}

# Jenkins home directory is a volume, so configuration and build history
# can be persisted and survive image upgrades
VOLUME $JENKINS_HOME

# $REF (defaults to `/usr/share/jenkins/ref/`) contains all reference configuration we want
# to set on a fresh new installation. Use it to bundle additional plugins
# or config file with your custom jenkins Docker image.
RUN mkdir -p ${REF}/init.groovy.d

# Use tini as subreaper in Docker container to adopt zombie processes
ARG TINI_VERSION=v0.19.0
COPY tini_pub.gpg "${JENKINS_HOME}/tini_pub.gpg"
RUN curl -fsSL "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${TARGETARCH}" -o /sbin/tini \
  && curl -fsSL "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${TARGETARCH}.asc" -o /sbin/tini.asc \
  && gpg --no-tty --import "${JENKINS_HOME}/tini_pub.gpg" \
  && gpg --verify /sbin/tini.asc \
  && rm -rf /sbin/tini.asc /root/.gnupg \
  && chmod +x /sbin/tini

# jenkins version being bundled in this docker image
ARG JENKINS_VERSION
ENV JENKINS_VERSION ${JENKINS_VERSION:-2.319.1}


# Can be used to customize where jenkins.war get downloaded from
ARG JENKINS_URL=https://repo.jenkins-ci.org/public/org/jenkins-ci/main/jenkins-war/${JENKINS_VERSION}/jenkins-war-${JENKINS_VERSION}.war
# https://nodejs.org/dist/v16.13.1/node-v16.13.1-linux-arm64.tar.xz
ARG NODEJS_URL=https://nodejs.org/dist/v16.13.1/node-v16.13.1-linux-x64.tar.xz
ARG M2_URL=https://archive.apache.org/dist/maven/maven-3/3.6.3/binaries/apache-maven-3.6.3-bin.tar.gz

# could use ADD but this one does not check Last-Modified header neither does it allow to control checksum
# see https://github.com/docker/docker/issues/8331
RUN curl -fsSL ${JENKINS_URL} -o /usr/share/jenkins/jenkins.war

ENV JENKINS_UC https://updates.jenkins.io
ENV JENKINS_UC_EXPERIMENTAL=https://updates.jenkins.io/experimental
ENV JENKINS_INCREMENTALS_REPO_MIRROR=https://repo.jenkins-ci.org/incrementals
RUN chown -R ${user} "$JENKINS_HOME" "$REF"

ARG PLUGIN_CLI_VERSION=2.9.3
ARG PLUGIN_CLI_URL=https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/${PLUGIN_CLI_VERSION}/jenkins-plugin-manager-${PLUGIN_CLI_VERSION}.jar
RUN curl -fsSL ${PLUGIN_CLI_URL} -o /opt/jenkins-plugin-manager.jar && \
    curl -fsSL ${NODEJS_URL} -o /opt/nodejs.tar && \
    curl -fsSL ${M2_URL} -o /opt/maven.tar && \
    mkdir -p /opt/nodejs /opt/maven && \
    tar -xvf /opt/nodejs.tar --strip-components 1 -C /opt/nodejs && \
    tar -xvf /opt/maven.tar --strip-components 1 -C /opt/maven && \
    rm -rf /opt/nodejs.tar /opt/maven.tar && \
    chmod +x /opt/nodejs/bin/* /opt/maven/bin/*
    
# for main web interface:
EXPOSE ${http_port}

# will be used by attached agents:
EXPOSE ${agent_port}

ENV COPY_REFERENCE_FILE_LOG $JENKINS_HOME/copy_reference_file.log

ENV PATH "${PATH}:/opt/nodejs/bin:/opt/maven/bin"

USER ${user}

COPY jenkins-support /usr/local/bin/jenkins-support
COPY jenkins.sh /usr/local/bin/jenkins.sh
COPY tini-shim.sh /bin/tini
COPY jenkins-plugin-cli.sh /bin/jenkins-plugin-cli
COPY plugins.txt ${REF}/

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/jenkins.sh"]

# from a derived Dockerfile, can use `RUN install-plugins.sh active.txt` to setup $REF/plugins from a support bundle
COPY install-plugins.sh /usr/local/bin/install-plugins.sh

RUN echo 'export PATH="${PATH}:/opt/nodejs/bin:/opt/maven/bin"' && \
    install-plugins.sh < ${REF}/plugins.txt

# metadata labels
LABEL \
    org.opencontainers.image.vendor="Jenkins project" \
    org.opencontainers.image.title="Official Jenkins Docker image" \
    org.opencontainers.image.description="The Jenkins Continuous Integration and Delivery server" \
    org.opencontainers.image.version="${JENKINS_VERSION}" \
    org.opencontainers.image.url="https://www.jenkins.io/" \
    org.opencontainers.image.source="https://github.com/jenkinsci/docker" \
    org.opencontainers.image.revision="${COMMIT_SHA}" \
    org.opencontainers.image.licenses="MIT"
