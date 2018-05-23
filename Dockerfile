FROM alpine:3.7

RUN apk add --update \
  bash \
  mongodb-tools \
  curl \
  python \
  py-pip \
  py-cffi \
  && pip install --upgrade pip \
  && apk add --virtual build-deps \
  gcc \
  libffi-dev \
  python-dev \
  linux-headers \
  musl-dev \
  openssl-dev \
  && pip install gsutil \
  && apk del build-deps \
  && rm -rf /var/cache/apk/*

ADD ./backup.sh /mongodb-gcs-backup/backup.sh
WORKDIR /mongodb-gcs-backup

RUN chmod +x /mongodb-gcs-backup/backup.sh

ENTRYPOINT ["/mongodb-gcs-backup/backup.sh"]
