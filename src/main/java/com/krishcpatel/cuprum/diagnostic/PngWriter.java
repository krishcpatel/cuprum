// SPDX-License-Identifier: LGPL-3.0-only
package com.krishcpatel.cuprum.diagnostic;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.CRC32;
import java.util.zip.DeflaterOutputStream;

/** Encodes GPU RGBA readbacks on the CPU without initializing AWT or an OpenGL toolkit. */
public final class PngWriter {
    private PngWriter() { }

    public static void write(Path path, ByteBuffer rgba, int width, int height, int stride, boolean flip) throws IOException {
        int rowSize = Math.multiplyExact(width, 4);
        if (width <= 0 || height <= 0 || stride < rowSize || (long) (height - 1) * stride + rowSize > rgba.remaining())
            throw new IllegalArgumentException("Invalid RGBA readback layout");
        var compressed = new ByteArrayOutputStream();
        try (var deflater = new DeflaterOutputStream(compressed)) {
            byte[] row = new byte[rowSize];
            for (int y=0; y<height; y++) {
                int sourceY = flip ? height - y - 1 : y;
                rgba.get(rgba.position() + sourceY * stride, row);
                deflater.write(0); // PNG filter: none.
                deflater.write(row);
            }
        }
        try (var out = new DataOutputStream(Files.newOutputStream(path))) {
            out.writeLong(0x89504e470d0a1a0aL);
            var header = new ByteArrayOutputStream();
            try (var fields = new DataOutputStream(header)) {
                fields.writeInt(width); fields.writeInt(height);
                fields.write(new byte[]{8, 6, 0, 0, 0}); // 8-bit RGBA, standard compression/filtering, no interlace.
            }
            chunk(out, "IHDR", header.toByteArray());
            chunk(out, "IDAT", compressed.toByteArray());
            chunk(out, "IEND", new byte[0]);
        }
    }

    private static void chunk(DataOutputStream out, String type, byte[] payload) throws IOException {
        byte[] name = type.getBytes(StandardCharsets.US_ASCII);
        var checksum = new CRC32();
        checksum.update(name); checksum.update(payload);
        out.writeInt(payload.length); out.write(name); out.write(payload); out.writeInt((int) checksum.getValue());
    }
}
