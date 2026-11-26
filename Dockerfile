# 서버에서 돌리기: docker build -t raid . && docker run -p 4567:4567 -e PORT=4567 -e RAID_ADMIN_PASSWORD=비밀번호 -v raid-data:/data raid
FROM ruby:3.3-slim
ENV LANG=C.UTF-8 RAID_DATA_DIR=/data PORT=4567
WORKDIR /app
COPY app ./app
COPY battle ./battle
RUN mkdir -p /data
EXPOSE 4567
CMD ["ruby", "app/run.rb"]
