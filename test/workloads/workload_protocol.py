"""Field encoding for the normalized workload interfaces."""


MASK128 = (1 << 128) - 1


def pack(*fields):
    result = 0
    for width, value in fields:
        value = int(value)
        if not 0 <= value < (1 << width):
            raise ValueError((width,value))
        result = result << width | value
    return result
