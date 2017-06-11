#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <libotr/proto.h>
#include <libotr/message.h>
#include <libotr/privkey.h>
#include <libgen.h>


#include "glirc-api.h"

#define MAJOR 1
#define MINOR 0

static OtrlPolicy op_policy(void *opdata, ConnContext *context) {
    return OTRL_POLICY_DEFAULT;
}

static void op_inject(void *opdata, const char *accountname,
  const char *protocol, const char *recipient, const char *message)
{
        char *message1 = strdup(message);
        for (char *cursor = message1; *cursor; cursor++) {
                if (*cursor == '\n') *cursor = ' ';
        }

        struct glirc *G = opdata;
        struct glirc_string params[2] =
        { { .str = recipient, .len = strlen(recipient) },
          { .str = message1, .len = strlen(message1) },
        };
        struct glirc_message m =
        {
                  .network = { .str = protocol, .len = strlen(protocol) } ,
                  .command = { .str = "PRIVMSG", .len = strlen("PRIVMSG") },
                  .params = params,
                  .params_n = 2
        };
        glirc_send_message(G, &m);
        free(message1);
}

static void op_msg_event(void *opdata, OtrlMessageEvent msg_event,
                ConnContext *context, const char *message,
                gcry_error_t err)
{
  struct glirc *G = opdata;
  if (message) {
    struct glirc_string m = { .str = message, .len = strlen(message) };
    glirc_print(G, ERROR_MESSAGE, m);
  }
}

static int op_max_message(void *opdata, ConnContext *context) {
        return 400; // pessmistic
}

static void op_create_privkey(void *opdata, const char *accountname, const char *protocol) {
        const char *txt = "No private key";
        struct glirc *G = opdata;
  struct glirc_string m = { .str = txt, .len = strlen(txt) };
  glirc_print(G, ERROR_MESSAGE, m);
}

int op_is_logged_in(void *opdata, const char *accountname, const char *protocol, const char *recipient) {
        return 1; // TODO: ask glirc if we share a channel, look in csUsers
}

static OtrlMessageAppOps ops = {
    .policy = op_policy,
    .create_privkey = op_create_privkey,
    .inject_message = op_inject,
    .max_message_size = op_max_message,
    .handle_msg_event = op_msg_event,
    .is_logged_in = op_is_logged_in
};

static void *start_entrypoint(struct glirc *G, const char *path)
{
        // TODO: Move this into message handler 001, use correct
        char keyfile[PATH_MAX] = {0};
        dirname_r(path, keyfile);
        strcat(keyfile, "/keyfile");
        OTRL_INIT;
        OtrlUserState us = otrl_userstate_create();
        otrl_privkey_generate(us, keyfile, "glguy", "elis.local");
        return us;
}

static void stop_entrypoint(struct glirc *G, void *L)
{
        OtrlUserState us = L;
        otrl_userstate_free(us);
}

static char *import_string(struct glirc_string s) {
        return strndup(s.str, s.len);
}

static enum process_result message_entrypoint(struct glirc *G, void *L, const struct glirc_message *msg)
{
    if (0 == strncmp("PRIVMSG", msg->command.str, msg->command.len) && msg->params_n == 2) {

        OtrlUserState us = L;
        char *newmessage = NULL;
        OtrlTLV *tlvs = NULL;

        char *sender = import_string(msg->prefix_nick);
        char *target = import_string(msg->params[0]);
        char *message = import_string(msg->params[1]);
        char *net = import_string(msg->network);

        int drop = otrl_message_receiving(us, &ops, G, target, net, sender,
                          message, &newmessage, &tlvs, NULL, NULL, NULL);

        if (newmessage) {
            glirc_inject_chat(G, msg->network.str, msg->network.len,
                                 msg->prefix_nick.str, msg->prefix_nick.len,
                                 msg->prefix_nick.str, msg->prefix_nick.len,
                                 newmessage, strlen(newmessage));
        }

        otrl_tlv_free(tlvs); // ignoring this for now
        otrl_message_free(newmessage);
        free(sender);
        free(target);
        free(message);
        free(net);

        return (newmessage || drop) ? DROP_MESSAGE : PASS_MESSAGE;
    }

    return PASS_MESSAGE;
}

static enum process_result chat_entrypoint(struct glirc *G, void *L, const struct glirc_chat *chat)
{
        OtrlUserState us = L;
        char * net = import_string(chat->network);
        char * tgt = import_string(chat->target );
        char * msg = import_string(chat->message);

        char * me = glirc_my_nick(G, chat->network);
        char *newmsg = NULL;

        int err = otrl_message_sending
          (us, &ops, G, me, net, tgt, OTRL_INSTAG_BEST, msg,
           NULL, &newmsg, OTRL_FRAGMENT_SEND_ALL, NULL, NULL, NULL);

        free(msg); free(tgt); free(net); free(me);

        if (newmsg) {
                otrl_message_free(newmsg);
                return DROP_MESSAGE;
        }

        if (err) {
                const char *errTxt = "PANIC: OTR encryption error";
                struct glirc_string m = { .str = errTxt, .len = strlen(errTxt) };
                glirc_print(G, ERROR_MESSAGE, m);
                return DROP_MESSAGE;
        }

        return PASS_MESSAGE;

}

struct glirc_extension extension = {
        .name            = "OTR",
        .major_version   = MAJOR,
        .minor_version   = MINOR,
        .start           = start_entrypoint,
        .stop            = stop_entrypoint,
        .process_message = message_entrypoint,
        .process_chat    = chat_entrypoint
};