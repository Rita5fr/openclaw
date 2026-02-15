import { Type } from "@sinclair/typebox";
import type { ChannelAgentTool } from "../types.js";

export function createWhatsAppChannelLookupTool(): ChannelAgentTool {
  return {
    label: "WhatsApp Channel Lookup",
    name: "whatsapp_channel_lookup",
    description:
      "Look up a WhatsApp Channel (newsletter) by invite link/code to get its JID for sending, " +
      "or list all channels the linked WhatsApp account follows.",
    parameters: Type.Object({
      action: Type.Unsafe<"lookup" | "list">({
        type: "string",
        enum: ["lookup", "list"],
      }),
      inviteLink: Type.Optional(Type.String()),
    }),
    execute: async (_toolCallId, args) => {
      const { requireActiveWebListener } = await import("../../../web/active-listener.js");
      const action = (args as { action?: string })?.action ?? "lookup";
      const { listener } = requireActiveWebListener();

      if (action === "list") {
        if (!listener.newsletterList) {
          return {
            content: [{ type: "text", text: "Newsletter listing is not available. The WhatsApp connection may not support this feature." }],
          };
        }
        const channels = await listener.newsletterList();
        if (channels.length === 0) {
          return {
            content: [{ type: "text", text: "No followed channels found." }],
          };
        }
        const lines = channels.map(
          (ch) =>
            `- **${ch.name}** (JID: \`${ch.id}\`)${ch.subscribersCount ? ` — ${ch.subscribersCount} subscribers` : ""}${ch.verified ? " ✅" : ""}${ch.inviteUrl ? ` — ${ch.inviteUrl}` : ""}`,
        );
        return {
          content: [{ type: "text", text: `Found ${channels.length} followed channel(s):\n\n${lines.join("\n")}` }],
        };
      }

      // action === "lookup"
      const inviteLink = (args as { inviteLink?: string })?.inviteLink?.trim();
      if (!inviteLink) {
        return {
          content: [{ type: "text", text: "Please provide an invite link or code. Example: https://whatsapp.com/channel/0029VaXXXXXX" }],
        };
      }
      if (!listener.newsletterGetByInvite) {
        return {
          content: [{ type: "text", text: "Channel lookup is not available. The WhatsApp connection may not support this feature." }],
        };
      }

      // Parse invite code from URL or use raw code
      const code = inviteLink.includes("/")
        ? inviteLink.split("/").pop()!.trim()
        : inviteLink;

      try {
        const info = await listener.newsletterGetByInvite(code);
        if (!info) {
          return {
            content: [{ type: "text", text: `Could not find a channel for invite code: ${code}` }],
          };
        }
        const details = [
          `**${info.name}**${info.verified ? " ✅" : ""}`,
          `- JID: \`${info.id}\``,
          info.description ? `- Description: ${info.description}` : null,
          info.subscribersCount != null ? `- Subscribers: ${info.subscribersCount}` : null,
          info.inviteUrl ? `- Invite: ${info.inviteUrl}` : null,
          "",
          `To send a message to this channel, use the JID \`${info.id}\` as the target.`,
        ]
          .filter((line) => line !== null)
          .join("\n");
        return {
          content: [{ type: "text", text: details }],
        };
      } catch (err) {
        return {
          content: [{ type: "text", text: `Failed to look up channel: ${String(err)}` }],
        };
      }
    },
  };
}
