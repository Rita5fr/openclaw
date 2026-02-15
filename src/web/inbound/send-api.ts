import type { AnyMessageContent, WAPresence } from "@whiskeysockets/baileys";
import type { ActiveWebSendOptions, NewsletterInfo } from "../active-listener.js";
import { recordChannelActivity } from "../../infra/channel-activity.js";
import { toWhatsappJid } from "../../utils.js";

function toNewsletterInfo(data: unknown): NewsletterInfo | null {
  if (!data || typeof data !== "object") return null;
  const d = data as Record<string, unknown>;
  const meta = d.thread_metadata as Record<string, unknown> | undefined;
  const id = d.id as string;
  if (!id) return null;
  const name = (meta?.name as Record<string, unknown>)?.text as string ?? id;
  const description = (meta?.description as Record<string, unknown>)?.text as string | undefined;
  const invite = meta?.invite as string | undefined;
  const subscribersCount = meta?.subscribers_count ? Number(meta.subscribers_count) : undefined;
  const verification = meta?.verification as string | undefined;
  const picturePath = (meta?.picture as Record<string, unknown>)?.direct_path as string | undefined;
  const picture = picturePath ? `https://pps.whatsapp.net${picturePath}` : undefined;
  return {
    id,
    name,
    description,
    invite,
    inviteUrl: invite ? `https://whatsapp.com/channel/${invite}` : undefined,
    subscribersCount,
    verified: verification === "VERIFIED",
    picture,
  };
}

export function createWebSendApi(params: {
  sock: {
    sendMessage: (jid: string, content: AnyMessageContent) => Promise<unknown>;
    sendPresenceUpdate: (presence: WAPresence, jid?: string) => Promise<unknown>;
    newsletterMetadata?: (type: "invite" | "jid", key: string) => Promise<unknown>;
    newsletterSubscribed?: () => Promise<unknown[]>;
  };
  defaultAccountId: string;
}) {
  return {
    sendMessage: async (
      to: string,
      text: string,
      mediaBuffer?: Buffer,
      mediaType?: string,
      sendOptions?: ActiveWebSendOptions,
    ): Promise<{ messageId: string }> => {
      const jid = toWhatsappJid(to);
      let payload: AnyMessageContent;
      if (mediaBuffer && mediaType) {
        if (mediaType.startsWith("image/")) {
          payload = {
            image: mediaBuffer,
            caption: text || undefined,
            mimetype: mediaType,
          };
        } else if (mediaType.startsWith("audio/")) {
          payload = { audio: mediaBuffer, ptt: true, mimetype: mediaType };
        } else if (mediaType.startsWith("video/")) {
          const gifPlayback = sendOptions?.gifPlayback;
          payload = {
            video: mediaBuffer,
            caption: text || undefined,
            mimetype: mediaType,
            ...(gifPlayback ? { gifPlayback: true } : {}),
          };
        } else {
          const fileName = sendOptions?.fileName?.trim() || "file";
          payload = {
            document: mediaBuffer,
            fileName,
            caption: text || undefined,
            mimetype: mediaType,
          };
        }
      } else {
        payload = { text };
      }
      const result = await params.sock.sendMessage(jid, payload);
      const accountId = sendOptions?.accountId ?? params.defaultAccountId;
      recordChannelActivity({
        channel: "whatsapp",
        accountId,
        direction: "outbound",
      });
      const messageId =
        typeof result === "object" && result && "key" in result
          ? String((result as { key?: { id?: string } }).key?.id ?? "unknown")
          : "unknown";
      return { messageId };
    },
    sendPoll: async (
      to: string,
      poll: { question: string; options: string[]; maxSelections?: number },
    ): Promise<{ messageId: string }> => {
      const jid = toWhatsappJid(to);
      const result = await params.sock.sendMessage(jid, {
        poll: {
          name: poll.question,
          values: poll.options,
          selectableCount: poll.maxSelections ?? 1,
        },
      } as AnyMessageContent);
      recordChannelActivity({
        channel: "whatsapp",
        accountId: params.defaultAccountId,
        direction: "outbound",
      });
      const messageId =
        typeof result === "object" && result && "key" in result
          ? String((result as { key?: { id?: string } }).key?.id ?? "unknown")
          : "unknown";
      return { messageId };
    },
    sendReaction: async (
      chatJid: string,
      messageId: string,
      emoji: string,
      fromMe: boolean,
      participant?: string,
    ): Promise<void> => {
      const jid = toWhatsappJid(chatJid);
      await params.sock.sendMessage(jid, {
        react: {
          text: emoji,
          key: {
            remoteJid: jid,
            id: messageId,
            fromMe,
            participant: participant ? toWhatsappJid(participant) : undefined,
          },
        },
      } as AnyMessageContent);
    },
    sendComposingTo: async (to: string): Promise<void> => {
      const jid = toWhatsappJid(to);
      if (jid.endsWith("@newsletter")) {
        return;
      }
      await params.sock.sendPresenceUpdate("composing", jid);
    },
    newsletterGetByInvite: params.sock.newsletterMetadata
      ? async (inviteCode: string) => {
          const raw = await params.sock.newsletterMetadata!("invite", inviteCode);
          return toNewsletterInfo(raw);
        }
      : undefined,
    newsletterGetByJid: params.sock.newsletterMetadata
      ? async (jid: string) => {
          const raw = await params.sock.newsletterMetadata!("jid", jid);
          return toNewsletterInfo(raw);
        }
      : undefined,
    newsletterList: params.sock.newsletterSubscribed
      ? async () => {
          const raw = await params.sock.newsletterSubscribed!();
          return raw.map(toNewsletterInfo).filter(Boolean) as NewsletterInfo[];
        }
      : undefined,
  } as const;
}
