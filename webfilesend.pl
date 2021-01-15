#!/usr/bin/env perl
use 5.020;
use warnings;
use Digest::SHA 'sha1';
use MIME::Base64 'encode_base64url';
use Math::Random::Secure 'rand';
use Mojolicious::Lite -signatures;
use Mojo::URL;
use Time::HiRes 'time';

$ENV{MOJO_INACTIVITY_TIMEOUT} ||= 300;

plugin 'Config';
my $mercury_url = app->config->{mercury} // die "No mercury broker URL configured\n";

helper generate_channel => sub ($c) {
  my $addr = $c->tx->remote_address // '127.0.0.1';
  return substr encode_base64url(sha1 rand() . time . \my $dummy . $addr), 0, 12;
};

get '/' => 'index';

websocket '/recv/:channel_id' => sub ($c) {
  my $tx = $c->render_later->tx;
  my $channel_id = $c->param('channel_id');
  $c->log->debug(sprintf '[%s] Browser Receive WebSocket opened', $channel_id);
  my $url = Mojo::URL->new($mercury_url)->path("/sub/$channel_id");
  $c->app->ua->websocket_p($url)->then(sub ($sub_tx) {
    $c->log->debug(sprintf '[%s] Mercury Subscribe WebSocket opened', $channel_id);
    $sub_tx->on(message => sub ($sub_tx, $msg) {
      $c->log->debug(sprintf '[%s] Received %d bytes from Mercury: %vX', $channel_id, length $msg, $msg);
      $c->send({binary => $msg});
    });
    $sub_tx->on(finish => sub ($sub_tx, $code = undef, $reason = undef) {
      $c->log->debug(sprintf '[%s] Mercury Subscribe WebSocket closed: %d %s', $channel_id, $code // 0, $reason // '');
      $c->finish;
      undef $tx;
    });
    $c->on(finish => sub ($c, $code = undef, $reason = undef) {
      $c->log->debug(sprintf '[%s] Browser Receive WebSocket closed: %d %s', $channel_id, $code // 0, $reason // '');
      $sub_tx->finish;
    });
  });
} => 'recv';

websocket '/send/:channel_id' => sub ($c) {
  my $tx = $c->render_later->tx;
  my $channel_id = $c->param('channel_id');
  $c->log->debug(sprintf '[%s] Browser Send WebSocket opened', $channel_id);
  my $url = Mojo::URL->new($mercury_url)->path("/pub/$channel_id");
  $c->app->ua->websocket_p($url)->then(sub ($pub_tx) {
    $c->log->debug(sprintf '[%s] Mercury Publish WebSocket opened', $channel_id);
    $c->on(binary => sub ($c, $bytes) {
      $c->log->debug(sprintf '[%s] Received %d bytes from Browser: %vX', $channel_id, length $bytes, $bytes);
      $pub_tx->send($bytes);
    });
    $c->on(finish => sub ($c, $code = undef, $reason = undef) {
      $c->log->debug(sprintf '[%s] Browser Send WebSocket closed: %d %s', $channel_id, $code // 0, $reason // '');
      $pub_tx->finish;
    });
    $pub_tx->on(finish => sub ($pub_tx, $code = undef, $reason = undef) {
      $c->log->debug(sprintf '[%s] Mercury Publish WebSocket closed: %d %s', $channel_id, $code // 0, $reason // '');
      $c->finish;
      undef $tx;
    });
    $c->send('ready');
  });
} => 'send';

app->start;

__DATA__
@@ index.html.ep
<html>
  <head>
    <title>WebFileSend</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@4.5.3/dist/css/bootstrap.min.css" integrity="sha384-TX8t27EcRE3e/ihU7zmQxVncDAy5uIKz4rEkgIXeMed4M0jlfIDPvg6uqKI2xXr2" crossorigin="anonymous">
  </head>
  <body>
    <div class="container" id="main" data-channel="<%= generate_channel %>" data-recv-url="<%= url_for('recv')->to_abs %>" data-send-url="<%= url_for('send')->to_abs %>">
      <h1>WebFileSend</h1>
      <form id="recv_form" class="form-inline" v-on:submit.prevent>
        <div class="form-group">
          <input type="text" class="form-control mr-2" v-bind:disabled="listening" v-model="recv_channel" placeholder="Channel">
          <template v-if="listening">
            <button v-on:click="close_channel" type="submit" class="btn btn-danger mr-2">Close Channel</button>
            <span>Listening on <a v-bind:href="'#' + encodeURIComponent(recv_channel)">{{ recv_channel }}</a></span>
          </template>
          <button v-else v-on:click="open_channel" type="submit" class="btn btn-success">Open Channel</button>
        </div>
      </form>
      <form class="form-inline" v-on:submit.prevent="send_to_channel">
        <div class="form-group">
          <input type="text" class="form-control mr-2" v-model="send_channel" placeholder="Channel">
          <input type="file" class="form-control mr-2" id="send_file_input">
          <button type="submit" class="btn btn-primary">Send to Channel</button>
        </div>
      </form>
      <div>{{ output }}</div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/vue@2.6.12/dist/vue.min.js" integrity="sha256-KSlsysqp7TXtFo/FHjb1T9b425x3hrvzjMWaJyKbpcI=" crossorigin="anonymous"></script>
    <script src="/webfilesend.js"></script>
  </body>
</html>

@@ webfilesend.js
var recv_ws;
var send_ws;
var app_data = { output: '', recv_channel: null, send_channel: null, listening: false };
var app = new Vue({
  el: '#main',
  data: app_data,
  created: function () {
    app_data.recv_channel = document.getElementById('main').dataset.channel;
    var hash = window.location.hash;
    if (hash !== null) {
      app_data.send_channel = hash.substring(1);
    }
  },
  methods: {
    open_channel: function (event) {
      var listen_button = event.target;
      listen_button.setAttribute('disabled', '');
      var ws_url = this.$el.dataset.recvUrl;
      if (ws_url.substring(ws_url.length - 1) !== '/') {
        ws_url += '/';
      }
      ws_url += encodeURIComponent(app_data.recv_channel);
      recv_ws = new WebSocket(ws_url);
      recv_ws.onerror = function (event) { console.error('WebSocket error:', event); };
      recv_ws.onmessage = function (event) {
        app_data.output += event.data;
      };
      recv_ws.onopen = function (event) {
        app_data.listening = true;
        listen_button.removeAttribute('disabled');
      };
      recv_ws.onclose = function (event) {
        listen_button.removeAttribute('disabled');
        app_data.listening = false;
      };
    },
    close_channel: function (event) {
      if (recv_ws !== null && recv_ws.readyState !== 3) {
        recv_ws.close();
      }
    },
    send_to_channel: function (event) {
      var ws_url = this.$el.dataset.sendUrl;
      if (ws_url.substring(ws_url.length - 1) !== '/') {
        ws_url += '/';
      }
      ws_url += encodeURIComponent(app_data.send_channel);
      send_ws = new WebSocket(ws_url);
      send_ws.binaryType = 'arraybuffer';
      send_ws.onerror = function (event) { console.error('WebSocket error:', event); };
      send_ws.onclose = function (event) { console.log('WebSocket closed:', event.code, event.reason); };
      send_ws.onmessage = function (event) {
        if (event.data == 'ready') {
          var buf = new ArrayBuffer(8);
          var bufView = new Uint8Array(buf);
          bufView.forEach(function (elem, index) { bufView[index] = 48 + index; });
          send_ws.send(buf);
          // websocket closes before this gets sent?
        }
      };
    }
  },
});
