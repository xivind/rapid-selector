// The only script besides htmx: htmx 2 swaps nothing on an error or no answer, so a failed
// kill switch request would otherwise look like nothing happened.
function towerRequestFailed(event) {
  var ks = document.getElementById("killswitch");
  if (!ks || !event.detail.elt || !event.detail.elt.closest("#killswitch")) return;
  var status = event.detail.xhr && event.detail.xhr.status;
  var p = ks.querySelector(".ks-failed") || ks.appendChild(document.createElement("p"));
  p.className = "warn ks-failed";
  p.setAttribute("role", "alert");
  p.textContent = "request failed (" + (status ? "HTTP " + status : "no answer") +
    ") — reload, or use the README's manual stop";
}
document.addEventListener("htmx:responseError", towerRequestFailed);
document.addEventListener("htmx:sendError", towerRequestFailed);
