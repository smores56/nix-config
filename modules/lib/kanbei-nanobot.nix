# Loopback ports for the nanobot instance inside the kanbei guest (smores56/sdlc#642).
#
# The guest has no NIC: two units that bind one port is a boot failure whose only trace is
# an EADDRINUSE line on the serial console, so every port lives here and the modules assert
# they stay distinct. nanobot serves its WebUI and its websocket channel from one server on
# `webPort`; the gateway's own HTTP surface (`/health`) is a second, separate listener.
{
  # The WebUI and websocket channel. T5 points the TLS terminator here.
  webPort = 8080;
  # The gateway's HTTP surface; the WebUI does not use it.
  gatewayPort = 8082;
  # The kernel's own chat lane held 8080 before nanobot existed. Nothing in the guest
  # dials it (`kanbei-ui` posts straight to llama.cpp), so it steps aside; T5 decides
  # whether it retires.
  kernelChatPort = 8083;
  kernelStatusPort = 8081;
}
