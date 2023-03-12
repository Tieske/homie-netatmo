FROM akorn/luarocks:lua5.1-alpine as build

RUN apk add \
    gcc \
    git \
    libc-dev \
    make \
    openssl-dev

# install dependencies separately to not have --dev versions for them as well
RUN luarocks install copas \
 && luarocks install luasec \
 && luarocks install penlight \
 && luarocks install Tieske/luamqtt --dev \
 && luarocks install homie --dev \
 && luarocks install luabitop

# copy the local repo contents and build it
COPY ./ /tmp/homie-netatmo
WORKDIR /tmp/homie-netatmo
RUN luarocks make

# collect cli scripts; the ones that contain "LUAROCKS_SYSCONFDIR" are Lua ones
RUN mkdir /luarocksbin \
 && grep -rl LUAROCKS_SYSCONFDIR /usr/local/bin | \
    while IFS= read -r filename; do \
      cp "$filename" /luarocksbin/; \
    done



FROM akorn/lua:5.1-alpine
RUN apk add --no-cache \
    ca-certificates \
    openssl

ENV NETATMO_CLIENT_ID "client-id..."
ENV NETATMO_CLIENT_SECRET "client-secret..."
ENV NETATMO_USERNAME "username..."
ENV NETATMO_PASSWORD "password..."
ENV NETATMO_POLL_INTERVAL "60"
ENV HOMIE_DOMAIN "homie"
ENV HOMIE_MQTT_URI "mqtt://mqtthost:1883"
ENV HOMIE_DEVICE_ID "netatmo"
ENV HOMIE_DEVICE_NAME "Netatmo-to-Homie bridge"
ENV HOMIE_LOG_LOGLEVEL "debug"

# copy luarocks tree and data over
COPY --from=build /luarocksbin/* /usr/local/bin/
COPY --from=build /usr/local/lib/lua /usr/local/lib/lua
COPY --from=build /usr/local/share/lua /usr/local/share/lua
COPY --from=build /usr/local/lib/luarocks /usr/local/lib/luarocks

CMD ["homienetatmo"]
