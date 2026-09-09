# hyprcrt Hyprland plugin. Builds against the installed Hyprland headers (pkg-config hyprland).
CXX      ?= g++
OPT      ?= -O2 -g
CXXFLAGS  = $(OPT) -std=c++23 -fPIC --no-gnu-unique -Wall -Wno-unused-parameter -Wno-missing-field-initializers
INCLUDES  = $(shell pkg-config --cflags hyprland hyprlang pixman-1 libdrm egl glesv2 lua)
LIBS      = $(shell pkg-config --libs egl glesv2)

SRC_DIR = src
OUT_DIR = out
OBJ_DIR = $(OUT_DIR)/obj
SRCS    = $(wildcard $(SRC_DIR)/*.cpp)
OBJS    = $(patsubst $(SRC_DIR)/%.cpp,$(OBJ_DIR)/%.o,$(SRCS))
TARGET  = $(OUT_DIR)/hyprcrt.so

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) -shared $^ -o $@ $(LIBS)

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cpp $(wildcard $(SRC_DIR)/*.hpp) | $(OBJ_DIR)
	$(CXX) $(INCLUDES) $(CXXFLAGS) -c $< -o $@

$(OBJ_DIR):
	@mkdir -p $@

clean:
	rm -rf $(OUT_DIR)

.PHONY: all clean
