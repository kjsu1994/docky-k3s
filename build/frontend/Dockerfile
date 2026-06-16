FROM nginx@sha256:540858b3a92eed95cbcae475698c12f619b4a6afa122485f439e4d7227cbeb38

RUN rm -rf /usr/share/nginx/html /usr/share/nginx/client
COPY dist/ /usr/share/nginx/client/current/

EXPOSE 80
