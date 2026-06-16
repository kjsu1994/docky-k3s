FROM eclipse-temurin@sha256:f57e47e7a78ae1ff5019681d95a4964153b0d1078bdff2a2f288e4a5ee329c14

RUN apk add --no-cache ffmpeg

WORKDIR /app
COPY app.jar /app/app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
